defmodule Strata.UI.Components.Sidebar do
  @moduledoc """
  Sidebar component rendering connections and database schemas in a collapsible Tree View.
  """

  @doc """
  Loads connection profiles from ConfigStore and builds hierarchical tree nodes.
  """
  def load_nodes do
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
      Enum.map(profiles, fn profile ->
        driver_label = String.upcase(to_string(profile.driver))
        display_name = if profile.name && profile.name != "", do: profile.name, else: "Connection"
        db_label = if profile.database && profile.database != "", do: profile.database, else: "public"

        tables = fetch_schema_tables(profile)

        table_nodes =
          Enum.map(tables, fn tbl ->
            %{
              id: "#{profile.id}_tbl_#{tbl}",
              label: tbl,
              type: :table,
              children: []
            }
          end)

        %{
          id: profile.id,
          label: "#{display_name} (#{driver_label})",
          type: :connection,
          expanded?: true,
          children: [
            %{
              id: "#{profile.id}_schema_#{db_label}",
              label: db_label,
              type: :schema,
              expanded?: true,
              children: table_nodes
            }
          ]
        }
      end)
    end
  end

  defp fetch_schema_tables(profile) do
    case Strata.ConnectionWorker.start_link(profile) do
      {:ok, worker} ->
        try do
          Strata.SchemaInspector.list_tables(worker, profile.driver)
        after
          Strata.ConnectionWorker.stop(worker)
        end

      _ ->
        []
    end
  rescue
    _ -> []
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
  Handles navigation keys in tree view (:up, :down, :right, :left, :enter).
  """
  def handle_key(%{sidebar_nodes: nodes, selected_tree_node_id: sel_id} = app, key) do
    visible = flatten_visible_nodes(nodes, sel_id)

    case key do
      :down ->
        next_node = get_neighbor(visible, sel_id, 1)
        if next_node, do: %{app | selected_tree_node_id: next_node.id}, else: app

      :up ->
        prev_node = get_neighbor(visible, sel_id, -1)
        if prev_node, do: %{app | selected_tree_node_id: prev_node.id}, else: app

      :right ->
        selected_item = Enum.find(visible, &(&1.id == sel_id))

        cond do
          selected_item && selected_item.has_children? and not selected_item.expanded? ->
            update_node_expanded(app, sel_id, true)

          true ->
            Strata.UI.App.set_focus(app, :datagrid)
        end

      :left ->
        selected_item = Enum.find(visible, &(&1.id == sel_id))

        if selected_item && selected_item.expanded? do
          update_node_expanded(app, sel_id, false)
        else
          app
        end

      k when k in [:enter, "r", "R"] ->
        selected_item = Enum.find(visible, &(&1.id == sel_id))

        if selected_item && selected_item.type in [:table, :view] do
          load_table_data(app, selected_item.label)
        else
          toggle_node_expanded(app, sel_id)
        end

      k when k in ["a", "A", {:ctrl, "a"}] ->
        Strata.UI.App.push_modal(app, Strata.UI.Components.ConnectionModal.new())

      k when k in ["e", "E", {:ctrl, "e"}] ->
        Strata.UI.App.push_modal(app, Strata.UI.Components.ConnectionModal.new())

      _other ->
        app
    end
  end

  @doc """
  Loads inspect data for selected table and switches to Table View.
  Executes SELECT * FROM table LIMIT 100 on live connection if available.
  """
  def load_table_data(app, table_name) do
    profiles =
      try do
        Strata.ConfigStore.list_profiles()
      catch
        _, _ -> []
      end

    sel_id = app.selected_tree_node_id

    profile =
      Enum.find(profiles, fn p -> sel_id && String.starts_with?(sel_id, p.id) end) ||
        List.first(profiles)

    {columns, rows, status_msg} =
      if profile do
        case fetch_real_table_data(profile, table_name) do
          {:ok, cols, data_rows} ->
            {cols, data_rows, "Loaded table '#{table_name}' (#{length(data_rows)} rows)"}

          {:error, reason} ->
            msg = if is_binary(reason), do: reason, else: inspect(reason)
            {["error"], [[msg]], "Error loading table '#{table_name}': #{msg}"}
        end
      else
        {["info"], [["No database connection configured"]], "No database connection configured"}
      end

    grid = Strata.UI.Components.DataGrid.new(columns, rows)

    app
    |> Strata.UI.App.switch_view(:table_view)
    |> Map.put(:selected_table, table_name)
    |> Map.put(:datagrid_state, grid)
    |> Map.put(:status_message, status_msg)
  end

  defp fetch_real_table_data(profile, table_name) do
    case Strata.ConnectionWorker.start_link(profile) do
      {:ok, pid} ->
        try do
          sql =
            case profile.driver do
              :sqlite -> "SELECT * FROM \"#{table_name}\" LIMIT 100;"
              :mysql -> "SELECT * FROM `#{table_name}` LIMIT 100;"
              _ -> "SELECT * FROM \"#{table_name}\" LIMIT 100;"
            end

          case Strata.ConnectionWorker.execute_query(pid, sql) do
            {:ok, %{columns: cols, rows: rows}} ->
              str_rows = Enum.map(rows, fn r -> Enum.map(r, &to_string/1) end)
              {:ok, cols, str_rows}

            {:error, reason} ->
              msg = if is_binary(reason), do: reason, else: inspect(reason)
              {:error, msg}

            _ ->
              {:error, "Failed to query table"}
          end
        after
          Strata.ConnectionWorker.stop(pid)
        end

      {:error, reason} ->
        msg = if is_binary(reason), do: reason, else: inspect(reason)
        {:error, msg}

      _ ->
        {:error, "Cannot connect to database"}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  @doc """
  Renders tree view state into structured render map for the sidebar area.
  Returns items, selected_index, and lines for ExRatatui.Widgets.List widget rendering.
  """
  def render(app, area) do
    visible = flatten_visible_nodes(app.sidebar_nodes, app.selected_tree_node_id)
    selected_idx = Enum.find_index(visible, &(&1.id == app.selected_tree_node_id)) || 0

    items =
      Enum.map(visible, fn item ->
        indent = String.duplicate("  ", item.depth)
        icon = type_icon(item.type, item.expanded?, item.has_children?)
        "#{indent}#{icon} #{item.label}"
      end)

    lines =
      Enum.map(visible, fn item ->
        indent = String.duplicate("  ", item.depth)
        icon = type_icon(item.type, item.expanded?, item.has_children?)
        prefix = if item.selected?, do: "> ", else: "  "

        %{
          text: "#{prefix}#{indent}#{icon} #{item.label}",
          selected?: item.selected?,
          type: item.type
        }
      end)

    %{
      title: "CONNECTIONS / SCHEMA",
      area: area,
      items: items,
      lines: lines,
      selected_index: selected_idx,
      selected_id: app.selected_tree_node_id
    }
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

  defp update_node_expanded(%{sidebar_nodes: nodes} = app, target_id, expanded?) when is_binary(target_id) do
    updated_nodes = map_tree(nodes, target_id, fn n -> Map.put(n, :expanded?, expanded?) end)
    %{app | sidebar_nodes: updated_nodes}
  end

  defp update_node_expanded(app, _target_id, _expanded?), do: app

  defp toggle_node_expanded(%{sidebar_nodes: nodes} = app, target_id) when is_binary(target_id) do
    updated_nodes =
      map_tree(nodes, target_id, fn n ->
        Map.update(n, :expanded?, true, &not &1)
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

  defp type_icon(:connection, _exp?, _children?), do: "🔌"
  defp type_icon(:schema, true, _children?), do: "📂"
  defp type_icon(:schema, false, _children?), do: "📁"
  defp type_icon(:table, _exp?, _children?), do: "📋"
  defp type_icon(:view, _exp?, _children?), do: "👁️"
  defp type_icon(:column, _exp?, _children?), do: "🔹"
  defp type_icon(_other, true, true), do: "▼"
  defp type_icon(_other, false, true), do: "▶"
  defp type_icon(_other, _exp?, false), do: "•"
end
