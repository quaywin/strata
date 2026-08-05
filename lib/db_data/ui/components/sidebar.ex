defmodule DBData.UI.Components.Sidebar do
  @moduledoc """
  Sidebar component rendering connections and database schemas in a collapsible Tree View.
  """

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
        update_node_expanded(app, sel_id, true)

      :left ->
        update_node_expanded(app, sel_id, false)

      :enter ->
        toggle_node_expanded(app, sel_id)

      _other ->
        app
    end
  end

  @doc """
  Renders tree view state into structured render map for the sidebar area.
  """
  def render(app, area) do
    visible = flatten_visible_nodes(app.sidebar_nodes, app.selected_tree_node_id)

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
      lines: lines,
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
