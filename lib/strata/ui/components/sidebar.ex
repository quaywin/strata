defmodule Strata.UI.Components.Sidebar do
  @moduledoc """
  Sidebar component rendering connections and database schemas in a collapsible Tree View.
  """

  @doc """
  Loads connection profiles from ConfigStore and builds lightweight initial tree nodes
  without blocking on network/DB I/O. Pass `live: true` to fetch live schemas synchronously.
  """
  def load_nodes(opts \\ []) do
    profiles =
      try do
        Strata.ConfigStore.list_profiles()
      catch
        _, _ -> []
      end

    if profiles == [] do
      [
        %{
          id: "no_conn_prompt",
          label: "(No connections configured)",
          type: :connection,
          expanded?: true,
          children: [
            %{
              id: "add_conn_hint",
              label: "Press [a] to Add Connection",
              type: :schema,
              expanded?: false,
              children: []
            }
          ]
        }
      ]
    else
      if Keyword.get(opts, :live, false) do
        fetch_all_tree_nodes(profiles)
      else
        Enum.map(profiles, fn profile ->
          %{
            id: profile.id,
            label: Strata.SchemaInspector.connection_label(profile),
            type: :connection,
            expanded?: false,
            children: [
              %{
                id: "#{profile.id}_loading",
                label: "Loading schema...",
                type: :schema,
                expanded?: false,
                children: []
              }
            ]
          }
        end)
      end
    end
  end

  @doc """
  Fetches live schema trees across all configured profiles concurrently.
  """
  def fetch_all_tree_nodes(profiles \\ nil) do
    profiles =
      profiles ||
        try do
          Strata.ConfigStore.list_profiles()
        catch
          _, _ -> []
        end

    if profiles == [] do
      load_nodes()
    else
      default_expanded? = length(profiles) == 1

      profiles
      |> Task.async_stream(
        fn profile ->
          Strata.SchemaInspector.fetch_tree_nodes(profile, expanded?: default_expanded?)
        end,
        max_concurrency: 4,
        timeout: 10_000,
        on_timeout: :kill_task
      )
      |> Enum.zip(profiles)
      |> Enum.map(fn
        {{:ok, node}, _profile} ->
          node

        {{:exit, _reason}, profile} ->
          Strata.SchemaInspector.fetch_fallback_nodes(profile, :timeout,
            expanded?: default_expanded?
          )
      end)
    end
  end

  @doc """
  Flattens hierarchical tree nodes into visible flat items based on `expanded?` state.
  """
  @spec flatten_visible_nodes([map()], String.t() | nil, integer()) :: [map()]
  def flatten_visible_nodes(nodes, selected_id \\ nil, depth \\ 0) do
    Enum.flat_map(nodes, fn node ->
      id = Map.get(node, :id)
      label = Map.get(node, :label, "")
      type = Map.get(node, :type, :generic)
      children = Map.get(node, :children, [])
      expanded? = Map.get(node, :expanded?, false)
      has_children? = children != []

      item = %{
        id: id,
        label: label,
        type: type,
        depth: depth,
        expanded?: expanded?,
        has_children?: has_children?,
        child_count: length(children),
        schema: Map.get(node, :schema),
        selected?: id == selected_id
      }

      if expanded? and has_children? do
        [item | flatten_visible_nodes(children, selected_id, depth + 1)]
      else
        [item]
      end
    end)
  end

  @doc """
  Returns the visible flattened list of tree nodes for `app`, applying `sidebar_filter` when present.
  """
  @spec visible_nodes(map()) :: [map()]
  def visible_nodes(%{sidebar_nodes: nodes, selected_tree_node_id: sel_id} = app) do
    filter = Map.get(app, :sidebar_filter, "") || ""

    if String.trim(filter) == "" do
      flatten_visible_nodes(nodes, sel_id)
    else
      filtered = filter_tree_nodes(nodes, String.downcase(String.trim(filter)))
      flatten_visible_nodes(filtered, sel_id)
    end
  end

  defp filter_tree_nodes(nodes, needle) do
    Enum.flat_map(nodes, fn node ->
      label_match? = node |> Map.get(:label, "") |> String.downcase() |> String.contains?(needle)
      children = Map.get(node, :children, [])
      filtered_children = filter_tree_nodes(children, needle)

      cond do
        filtered_children != [] ->
          [Map.merge(node, %{expanded?: true, children: filtered_children})]

        label_match? ->
          [node]

        true ->
          []
      end
    end)
  end

  @doc """
  Handles navigation keys in tree view (:up, :down, :right, :left, :enter).
  """
  def handle_key(%{sidebar_nodes: _nodes, selected_tree_node_id: sel_id} = app, key) do
    visible = visible_nodes(app)

    case key do
      :down ->
        next_node = get_neighbor(visible, sel_id, 1)

        if next_node do
          new_idx = Enum.find_index(visible, &(&1.id == next_node.id)) || 0
          viewport_h = sidebar_viewport_h(app)
          offset = Map.get(app, :sidebar_scroll_offset, 0)
          new_offset = ensure_visible(offset, new_idx, viewport_h, length(visible))
          %{app | selected_tree_node_id: next_node.id, sidebar_scroll_offset: new_offset}
        else
          app
        end

      :up ->
        prev_node = get_neighbor(visible, sel_id, -1)

        if prev_node do
          new_idx = Enum.find_index(visible, &(&1.id == prev_node.id)) || 0
          viewport_h = sidebar_viewport_h(app)
          offset = Map.get(app, :sidebar_scroll_offset, 0)
          new_offset = ensure_visible(offset, new_idx, viewport_h, length(visible))
          %{app | selected_tree_node_id: prev_node.id, sidebar_scroll_offset: new_offset}
        else
          app
        end

      :right ->
        selected_item = Enum.find(visible, &(&1.id == sel_id))

        cond do
          (selected_item && selected_item.has_children? == true) and
              selected_item.expanded? != true ->
            update_node_expanded(app, sel_id, true)

          true ->
            Strata.UI.App.set_focus(app, :datagrid)
        end

      :left ->
        selected_item = Enum.find(visible, &(&1.id == sel_id))

        cond do
          (selected_item && selected_item.expanded?) and selected_item.has_children? ->
            update_node_expanded(app, sel_id, false)

          selected_item && selected_item.depth > 0 ->
            sel_idx = Enum.find_index(visible, &(&1.id == sel_id)) || 0

            parent_node =
              visible
              |> Enum.take(sel_idx)
              |> Enum.reverse()
              |> Enum.find(fn n -> n.depth < selected_item.depth end)

            if parent_node do
              new_idx = Enum.find_index(visible, &(&1.id == parent_node.id)) || 0
              viewport_h = sidebar_viewport_h(app)
              offset = Map.get(app, :sidebar_scroll_offset, 0)
              new_offset = ensure_visible(offset, new_idx, viewport_h, length(visible))
              %{app | selected_tree_node_id: parent_node.id, sidebar_scroll_offset: new_offset}
            else
              app
            end

          true ->
            app
        end

      k when k in [:enter, :space, " "] ->
        selected_item = Enum.find(visible, &(&1.id == sel_id))

        if selected_item && selected_item.type in [:table, :view] do
          load_table_data(app, selected_item.label)
        else
          toggle_node_expanded(app, sel_id)
        end

      k when k in ["r", "R", :f5] ->
        Strata.UI.App.refresh_sidebar_selection(app)

      k when k in ["c", "C"] ->
        collapse_all_nodes(app)

      k when k in ["o", "O", "x", "X"] ->
        expand_all_nodes(app)

      k when k in ["a", "A", {:ctrl, "a"}] ->
        Strata.UI.App.push_modal(app, Strata.UI.Components.ConnectionModal.new())

      k when k in ["e", "E"] ->
        case resolve_profile_for_selection(app) do
          nil ->
            %{app | status_message: "No connection selected to edit"}

          profile ->
            Strata.UI.App.push_modal(
              app,
              Strata.UI.Components.ConnectionModal.new(profile: profile)
            )
        end

      k when k in ["d", "D"] ->
        delete_selected_connection(app)

      "/" ->
        %{app | sidebar_filter_active: true, sidebar_filter: Map.get(app, :sidebar_filter, "")}

      _other ->
        app
    end
  end

  defp delete_selected_connection(app) do
    sel_id = app.selected_tree_node_id

    profile =
      try do
        Strata.ConfigStore.list_profiles()
        |> Enum.find(&(&1.id == sel_id))
      catch
        _, _ -> nil
      end

    if profile do
      modal = %{
        type: :confirm_delete_connection,
        title: "CONFIRM DELETE",
        profile_id: profile.id,
        profile_name: profile.name,
        content:
          "\n  Delete connection '#{profile.name}'?\n\n  All cached schema/table state for this profile will be cleared.\n\n  [y / Enter] Confirm Delete    [n / Esc] Cancel"
      }

      Strata.UI.App.push_modal(app, modal)
    else
      %{app | status_message: "Select a connection node to delete"}
    end
  end

  @doc """
  Executes actual deletion of connection `profile_id` after user confirmation.
  """
  def delete_connection_by_id(app, profile_id) when is_binary(profile_id) do
    profile =
      try do
        Strata.ConfigStore.get_profile(profile_id)
      catch
        _, _ -> nil
      end

    _ = Strata.ConnectionSupervisor.stop_worker(profile_id)
    _ = Strata.DataStore.invalidate_connection_cache(profile_id)

    try do
      Strata.ConfigStore.delete_profile(profile_id)
    catch
      _, _ -> :ok
    end

    nodes = load_nodes()

    first_id =
      case List.first(nodes) do
        nil -> nil
        n -> n.id
      end

    name = (profile && profile.name) || profile_id

    %{
      app
      | sidebar_nodes: nodes,
        selected_tree_node_id: first_id,
        status_message: "🗑️ Deleted connection '#{name}'"
    }
  end

  @doc """
  Resolves `{profile, schema}` for the selected tree node.
  """
  def resolve_selection_context(app) do
    profile = resolve_profile_for_selection(app)
    node = find_node_by_id(app.sidebar_nodes, app.selected_tree_node_id)
    schema = if node, do: Map.get(node, :schema), else: nil
    {profile, schema}
  end

  defp find_node_by_id([], _id), do: nil
  defp find_node_by_id(_nodes, nil), do: nil

  defp find_node_by_id([node | rest], id) do
    if node.id == id do
      node
    else
      find_node_by_id(Map.get(node, :children, []), id) || find_node_by_id(rest, id)
    end
  end

  @doc """
  Resolves matching `ConnectionProfile` for the selected tree node.
  """
  def resolve_profile_for_selection(app) do
    profiles =
      try do
        Strata.ConfigStore.list_profiles()
      catch
        _, _ -> []
      end

    sel_id = app.selected_tree_node_id

    Enum.find(profiles, fn p -> sel_id && String.starts_with?(sel_id, p.id) end) ||
      List.first(profiles)
  end

  @doc """
  Loads inspect data for selected table, auto-focuses DataGrid, and switches to Table View.
  Reads from ETS DataStore cache first (scoped by `{profile_id, schema, table}`),
  otherwise queries the persistent connection worker and caches the result.
  """
  def load_table_data(app, table_name, opts \\ []) do
    Strata.UI.App.load_table_async(app, table_name, opts)
  end

  @doc """
  Builds a safely quoted `table` or `schema.table` reference for the given driver.
  """
  def qualify_table(driver, table_name, nil),
    do: Strata.Adapter.quote_identifier(driver, table_name)

  def qualify_table(driver, table_name, ""),
    do: Strata.Adapter.quote_identifier(driver, table_name)

  def qualify_table(driver, table_name, schema) do
    case Strata.Adapter.normalize_driver(driver) do
      :postgres ->
        Strata.Adapter.quote_identifier(driver, schema) <>
          "." <> Strata.Adapter.quote_identifier(driver, table_name)

      _ ->
        Strata.Adapter.quote_identifier(driver, table_name)
    end
  end

  @doc """
  Fetches a chunk of rows from `table_name` starting at `offset` with limit `limit`.
  Supports optional `:schema`, `:order_by` (`{col_name, :asc | :desc}`), and `:where`.
  Reuses persistent ConnectionWorker and preserves raw cell types for `Strata.Formatter`.
  Returns `{:ok, columns, rows}` or `{:error, reason}`.
  """
  def fetch_table_chunk(profile, table_name, offset, limit \\ 100, opts \\ []) do
    schema = Keyword.get(opts, :schema)
    order_by = Keyword.get(opts, :order_by)
    where_clause = Keyword.get(opts, :where)
    qualified_table = qualify_table(profile.driver, table_name, schema)

    where_sql =
      if is_binary(where_clause) and String.trim(where_clause) != "" do
        " WHERE #{String.trim(where_clause)}"
      else
        ""
      end

    order_sql =
      case order_by do
        {col_name, dir} when is_binary(col_name) and dir in [:asc, :desc] ->
          q_col = Strata.Adapter.quote_identifier(profile.driver, col_name)
          dir_sql = if dir == :asc, do: "ASC", else: "DESC"
          " ORDER BY #{q_col} #{dir_sql}"

        _ ->
          ""
      end

    sql =
      "SELECT * FROM #{qualified_table}#{where_sql}#{order_sql} LIMIT #{limit} OFFSET #{offset};"

    case Strata.ConnectionWorker.execute_query_for_profile(profile, sql) do
      {:ok, %{columns: cols, rows: rows}} ->
        {:ok, cols, rows}

      {:error, reason} ->
        {:error, Strata.Formatter.format_error(reason)}

      _ ->
        {:error, "Failed to query table"}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  @doc """
  Fetches exact total row count (`SELECT COUNT(*)`) for a table.
  """
  @spec fetch_table_count(Strata.ConnectionProfile.t(), String.t(), keyword()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def fetch_table_count(profile, table_name, opts \\ []) do
    schema = Keyword.get(opts, :schema)
    qualified_table = qualify_table(profile.driver, table_name, schema)
    sql = "SELECT COUNT(*) FROM #{qualified_table};"

    case Strata.ConnectionWorker.execute_query_for_profile(profile, sql) do
      {:ok, %{rows: [[count | _] | _]}} when is_integer(count) ->
        {:ok, count}

      {:ok, %{rows: [[count | _] | _]}} when is_binary(count) ->
        case Integer.parse(count) do
          {int, _} -> {:ok, int}
          :error -> {:error, :invalid_count}
        end

      {:error, reason} ->
        {:error, reason}

      _ ->
        {:error, :invalid_count}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  @doc """
  Collapses all expandable tree nodes in sidebar.
  """
  def collapse_all_nodes(%{sidebar_nodes: nodes} = app) do
    updated = map_all_nodes(nodes, fn n -> Map.put(n, :expanded?, false) end)
    %{app | sidebar_nodes: updated, sidebar_scroll_offset: 0}
  end

  @doc """
  Expands/explores all expandable tree nodes in sidebar.
  """
  def expand_all_nodes(%{sidebar_nodes: nodes} = app) do
    updated = map_all_nodes(nodes, fn n -> Map.put(n, :expanded?, true) end)
    %{app | sidebar_nodes: updated}
  end

  defp map_all_nodes(nodes, func) do
    Enum.map(nodes, fn node ->
      node = func.(node)
      children = Map.get(node, :children, [])

      if children != [] do
        Map.put(node, :children, map_all_nodes(children, func))
      else
        node
      end
    end)
  end

  @doc """
  Renders only the visible viewport slice of the sidebar tree so scrolling DataGrid
  or Inspector does not build `Span`/`Line` structs for off-screen tree nodes.
  """
  def render_viewport(app, area) do
    visible = visible_nodes(app)
    total = length(visible)
    viewport_h = max(1, area.height - 2)
    scroll_offset = Map.get(app, :sidebar_scroll_offset, 0)
    max_offset = max(0, total - viewport_h)
    clamped_offset = min(scroll_offset, max_offset)
    selected_idx = Enum.find_index(visible, &(&1.id == app.selected_tree_node_id)) || 0

    statuses = Map.get(app, :connection_statuses, %{})
    active_table = Map.get(app, :selected_table)
    active_schema = Map.get(app, :selected_schema)

    styled_items =
      visible
      |> Enum.slice(clamped_offset, viewport_h)
      |> Enum.map(fn item ->
        {_plain, line} = format_sidebar_item(item, statuses, active_table, active_schema)
        line
      end)

    %{
      title: sidebar_title(app),
      styled_items: styled_items,
      selected_index: selected_idx,
      total: total,
      max_offset: max_offset,
      clamped_offset: clamped_offset,
      viewport_h: viewport_h
    }
  end

  defp sidebar_title(app) do
    filter = Map.get(app, :sidebar_filter, "") || ""
    filter_active? = Map.get(app, :sidebar_filter_active, false)

    if filter_active? or filter != "" do
      cursor = if filter_active?, do: "▌", else: ""
      "CONNECTIONS / 🔍 #{filter}#{cursor}"
    else
      "CONNECTIONS / SCHEMA"
    end
  end

  defp format_sidebar_item(item, statuses, active_table, active_schema) do
    alias ExRatatui.Style
    alias ExRatatui.Text.{Line, Span}

    indent = String.duplicate("  ", item.depth)

    is_hint? =
      is_binary(item.id) and
        (String.ends_with?(item.id, "_loading") or String.ends_with?(item.id, "_status") or
           item.id == "add_conn_hint")

    count_suffix =
      if item.type == :schema and not is_hint? and (item[:child_count] || 0) > 0,
        do: " (#{item.child_count})",
        else: ""

    active_table? =
      item.type in [:table, :view] and is_binary(active_table) and item.label == active_table and
        (is_nil(active_schema) or is_nil(item[:schema]) or item[:schema] == active_schema)

    {glyph, glyph_style, label_style} =
      case item.type do
        :connection ->
          {dot, dot_fg} =
            case Map.get(statuses, item.id) do
              :connected -> {"●", :green}
              :connecting -> {"◐", :yellow}
              :disconnected -> {"○", :red}
              _ -> {"●", :cyan}
            end

          {dot, %Style{fg: dot_fg, modifiers: [:bold]}, %Style{fg: :white, modifiers: [:bold]}}

        :schema ->
          if is_hint? do
            h_fg = if String.contains?(item.label, "Offline"), do: :red, else: :dark_gray
            {"!", %Style{fg: h_fg}, %Style{fg: h_fg}}
          else
            arrow = if item.expanded?, do: "▾", else: "▸"
            {arrow, %Style{fg: :cyan}, %Style{fg: :cyan, modifiers: [:bold]}}
          end

        :view ->
          l_style =
            if active_table?, do: %Style{fg: :green, modifiers: [:bold]}, else: %Style{fg: :blue}

          {"◫", %Style{fg: :cyan}, l_style}

        :table ->
          l_style =
            if active_table?, do: %Style{fg: :green, modifiers: [:bold]}, else: %Style{fg: :white}

          {"▦", %Style{fg: if(active_table?, do: :green, else: :dark_gray)}, l_style}

        _ ->
          {type_icon(item.type, item.expanded?, item.has_children?), %Style{}, %Style{}}
      end

    plain = "#{indent}#{glyph} #{item.label}#{count_suffix}"

    spans =
      [
        Span.new("#{indent}#{glyph} ", style: glyph_style),
        Span.new(item.label, style: label_style)
      ] ++
        if(count_suffix != "",
          do: [Span.new(count_suffix, style: %Style{fg: :dark_gray})],
          else: []
        )

    {plain, Line.new(spans)}
  end

  defp get_neighbor([], _sel_id, _delta), do: nil

  defp get_neighbor(visible, nil, _delta) do
    List.first(visible)
  end

  defp get_neighbor(visible, sel_id, delta) do
    idx = Enum.find_index(visible, &(&1.id == sel_id))

    case idx do
      nil -> List.first(visible)
      i -> Enum.at(visible, max(0, min(length(visible) - 1, i + delta)))
    end
  end

  defp update_node_expanded(%{sidebar_nodes: nodes} = app, target_id, expanded?)
       when is_binary(target_id) do
    updated_nodes = map_tree(nodes, target_id, fn n -> Map.put(n, :expanded?, expanded?) end)
    %{app | sidebar_nodes: updated_nodes}
  end

  defp update_node_expanded(app, _target_id, _expanded?), do: app

  defp toggle_node_expanded(%{sidebar_nodes: nodes} = app, target_id) when is_binary(target_id) do
    updated_nodes =
      map_tree(nodes, target_id, fn n ->
        Map.update(n, :expanded?, true, &(not &1))
      end)

    %{app | sidebar_nodes: updated_nodes}
  end

  defp toggle_node_expanded(app, _target_id), do: app

  defp map_tree(nodes, target_id, func) do
    Enum.map(nodes, fn node ->
      node =
        if node.id == target_id do
          func.(node)
        else
          node
        end

      children = Map.get(node, :children, [])

      if children != [] do
        Map.put(node, :children, map_tree(children, target_id, func))
      else
        node
      end
    end)
  end

  defp type_icon(:column, _exp?, _children?), do: "·"
  defp type_icon(_other, true, true), do: "▾"
  defp type_icon(_other, false, true), do: "▸"
  defp type_icon(_other, _exp?, false), do: "•"

  defp sidebar_viewport_h(app) do
    {_w, h} = Map.get(app, :window_size, {120, 40})
    footer_height = 1
    content_height = max(1, h - footer_height)
    # sidebar viewport = content_height - 2 (top + bottom borders)
    max(1, content_height - 2)
  end

  defp ensure_visible(current_offset, selected_idx, viewport_h, total) do
    max_offset = max(0, total - viewport_h)

    cond do
      selected_idx < current_offset ->
        max(0, selected_idx)

      selected_idx >= current_offset + viewport_h ->
        min(selected_idx - viewport_h + 1, max_offset)

      true ->
        min(current_offset, max_offset)
    end
  end
end
