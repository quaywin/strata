defmodule Strata.AI.ContextBuilder do
  @moduledoc """
  Collects safe, metadata-only database context from `Strata.UI.App`,
  `Strata.DataStore`, and `Strata.SchemaInspector` for AI SQL Query Editor prompts.
  Never includes row values or connection credentials.
  """

  alias Strata.Adapter
  alias Strata.AISettings
  alias Strata.DataStore
  alias Strata.SchemaInspector
  alias Strata.UI.Components.Sidebar

  @max_schema_chars 6_000
  @max_other_tables 50

  @doc """
  Builds a structured context map for the current `app` state and `settings`.

  Options:
  - `:fetch_missing?` - whether to query `SchemaInspector` if a table's schema is missing from ETS cache (default `true`).
  """
  @spec build(map(), AISettings.t(), keyword()) :: map()
  def build(app, %AISettings{} = settings, opts \\ []) do
    fetch_missing? = Keyword.get(opts, :fetch_missing?, true)
    {profile, tree_schema} = resolve_profile_and_schema(app)

    driver =
      case profile do
        %{driver: d} -> Adapter.normalize_driver(d)
        _ -> :postgres
      end

    dialect = dialect_label(driver)
    focused_table = Map.get(app, :selected_table)
    focused_schema = Map.get(app, :selected_schema) || tree_schema

    focused_schema_info =
      if is_binary(focused_table) and focused_table != "" do
        load_table_schema(profile, focused_schema, focused_table, app, fetch_missing?)
      else
        nil
      end

    related_blocks =
      if settings.context_scope == :focused_and_related do
        build_related_blocks(
          app,
          profile,
          focused_schema,
          focused_table,
          focused_schema_info,
          fetch_missing?
        )
      else
        []
      end

    focused_block =
      if is_binary(focused_table) and focused_table != "" do
        [
          format_table_block(
            qualified_name(focused_schema, focused_table),
            focused_schema_info,
            true
          )
        ]
      else
        []
      end

    schema_summary =
      (focused_block ++ related_blocks)
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n\n")
      |> truncate_chars(@max_schema_chars)

    active_tab = resolve_active_tab(app)

    %{
      driver: driver,
      dialect: dialect,
      focused_schema: focused_schema,
      focused_table: focused_table,
      focused_table_ref: qualified_name(focused_schema, focused_table) || "(none)",
      schema_summary:
        if(schema_summary == "", do: "(No active table or schema metadata)", else: schema_summary),
      current_sql: (active_tab && Map.get(active_tab, :content)) || "",
      last_error: active_tab && Map.get(active_tab, :last_query_error)
    }
  end

  @doc """
  Maps a normalized driver atom to a human-readable SQL dialect label.
  """
  @spec dialect_label(atom()) :: String.t()
  def dialect_label(:postgres), do: "PostgreSQL"
  def dialect_label(:mysql), do: "MySQL"
  def dialect_label(:sqlite), do: "SQLite"
  def dialect_label(other), do: String.upcase(to_string(other))

  defp resolve_profile_and_schema(app) do
    Sidebar.resolve_selection_context(app)
  rescue
    _ -> {nil, Map.get(app, :selected_schema)}
  end

  defp resolve_active_tab(app) do
    tabs = Map.get(app, :tabs, [])
    active_id = Map.get(app, :active_tab_id)
    Enum.find(tabs, &(Map.get(&1, :id) == active_id))
  end

  defp load_table_schema(nil, _schema, table_name, app, _fetch_missing?) do
    fallback_schema_from_grid(app, table_name)
  end

  defp load_table_schema(profile, schema, table_name, app, fetch_missing?) do
    case DataStore.get_schema_cache(profile.id, schema, table_name) do
      {:ok, info} ->
        info

      :miss when fetch_missing? ->
        case SchemaInspector.fetch_table_schema(profile, table_name, schema: schema) do
          {:ok, info} ->
            DataStore.put_schema_cache(profile.id, schema, table_name, info)
            info

          _ ->
            fallback_schema_from_grid(app, table_name)
        end

      :miss ->
        fallback_schema_from_grid(app, table_name)
    end
  end

  defp fallback_schema_from_grid(app, table_name) do
    if Map.get(app, :selected_table) == table_name do
      case Map.get(app, :datagrid_state) do
        %{columns: cols} when is_list(cols) and cols != [] ->
          rows = Enum.map(cols, fn c -> [to_string(c), "unknown", "YES", nil, "", ""] end)

          %{
            columns: ["Column", "Type", "Nullable", "Default", "Key", "Extra"],
            rows: rows,
            primary_keys: []
          }

        _ ->
          nil
      end
    else
      nil
    end
  end

  defp build_related_blocks(
         app,
         profile,
         focused_schema,
         focused_table,
         focused_info,
         fetch_missing?
       ) do
    fk_tables = extract_fk_tables(focused_info)

    fk_blocks =
      fk_tables
      |> Enum.reject(&(&1 == focused_table))
      |> Enum.uniq()
      |> Enum.take(8)
      |> Enum.map(fn tbl ->
        info = load_table_schema(profile, focused_schema, tbl, app, fetch_missing?)
        format_table_block(qualified_name(focused_schema, tbl), info, false)
      end)

    cached_cols =
      if profile && is_binary(Map.get(profile, :id)) do
        DataStore.cached_columns(profile.id)
      else
        %{}
      end

    sidebar_tables = collect_profile_tables(app, profile)

    other_tables =
      (sidebar_tables ++ Map.keys(cached_cols))
      |> Enum.uniq()
      |> Enum.reject(&(&1 in [focused_table | fk_tables]))
      |> Enum.take(@max_other_tables)

    other_block =
      if other_tables == [] do
        ""
      else
        lines =
          Enum.map(other_tables, fn tbl ->
            case Map.get(cached_cols, tbl) do
              cols when is_list(cols) and cols != [] ->
                "- #{tbl} (#{Enum.join(Enum.take(cols, 15), ", ")})"

              _ ->
                "- #{tbl}"
            end
          end)

        "OTHER TABLES IN CONNECTION:\n" <> Enum.join(lines, "\n")
      end

    fk_blocks ++ [other_block]
  end

  defp collect_profile_tables(app, profile) do
    nodes = Map.get(app, :sidebar_nodes, [])
    profile_id = profile && Map.get(profile, :id)

    target_nodes =
      if is_binary(profile_id) do
        case Enum.find(nodes, &(Map.get(&1, :id) == profile_id)) do
          nil -> nodes
          conn_node -> [conn_node]
        end
      else
        nodes
      end

    collect_table_labels(target_nodes, [])
    |> Enum.reverse()
    |> Enum.uniq()
  end

  defp collect_table_labels([], acc), do: acc

  defp collect_table_labels([node | rest], acc) do
    acc =
      if Map.get(node, :type) in [:table, :view] do
        [to_string(Map.get(node, :label, "")) | acc]
      else
        acc
      end

    acc = collect_table_labels(Map.get(node, :children, []), acc)
    collect_table_labels(rest, acc)
  end

  defp extract_fk_tables(nil), do: []

  defp extract_fk_tables(%{rows: rows}) when is_list(rows) do
    Enum.flat_map(rows, fn row ->
      extra = to_string(Enum.at(row, 5) || "")

      case Regex.run(~r/->\s*([^\s(]+)\(/, extra) do
        [_, ref_tbl] ->
          ref_tbl
          |> String.split(".")
          |> List.last()
          |> List.wrap()

        _ ->
          []
      end
    end)
  end

  defp extract_fk_tables(_), do: []

  defp format_table_block(nil, _info, _focused?), do: ""
  defp format_table_block("", _info, _focused?), do: ""

  defp format_table_block(table_ref, nil, focused?) do
    header = if focused?, do: "FOCUSED TABLE #{table_ref}", else: "RELATED TABLE #{table_ref}"
    "#{header}: (columns unknown)"
  end

  defp format_table_block(table_ref, %{rows: rows}, focused?) when is_list(rows) do
    header = if focused?, do: "FOCUSED TABLE #{table_ref}", else: "RELATED TABLE #{table_ref}"

    col_lines =
      Enum.map(rows, fn row ->
        col = Enum.at(row, 0, "")
        type = Enum.at(row, 1, "")
        nullable = Enum.at(row, 2, "YES")
        key = to_string(Enum.at(row, 4, "") || "")
        extra = to_string(Enum.at(row, 5, "") || "")

        tags =
          [
            if(key != "", do: key),
            if(nullable == "NO", do: "NOT NULL"),
            if(extra != "", do: extra)
          ]
          |> Enum.reject(&is_nil/1)
          |> Enum.join(" ")

        if tags == "" do
          "  - #{col}: #{type}"
        else
          "  - #{col}: #{type} [#{tags}]"
        end
      end)

    header <> ":\n" <> Enum.join(col_lines, "\n")
  end

  defp format_table_block(table_ref, _info, focused?) do
    header = if focused?, do: "FOCUSED TABLE #{table_ref}", else: "RELATED TABLE #{table_ref}"
    "#{header}: (columns unknown)"
  end

  defp qualified_name(_schema, nil), do: nil
  defp qualified_name(_schema, ""), do: nil
  defp qualified_name(nil, table), do: table
  defp qualified_name("", table), do: table
  defp qualified_name(schema, table), do: "#{schema}.#{table}"

  defp truncate_chars(str, max_len) when byte_size(str) <= max_len, do: str

  defp truncate_chars(str, max_len) do
    String.slice(str, 0, max_len) <> "\n... (schema truncated)"
  end
end
