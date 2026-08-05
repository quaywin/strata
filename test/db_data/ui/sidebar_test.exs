defmodule DBData.UI.Components.SidebarTest do
  use ExUnit.Case, async: true

  alias DBData.UI.App
  alias DBData.UI.Components.Sidebar

  setup do
    sample_nodes = [
      %{
        id: "conn_pg",
        label: "Prod Postgres",
        type: :connection,
        expanded?: true,
        children: [
          %{
            id: "conn_pg_public",
            label: "public",
            type: :schema,
            expanded?: true,
            children: [
              %{id: "conn_pg_public_users", label: "users", type: :table, expanded?: false, children: []},
              %{id: "conn_pg_public_orders", label: "orders", type: :table, expanded?: false, children: []}
            ]
          }
        ]
      },
      %{
        id: "conn_sqlite",
        label: "Local SQLite",
        type: :connection,
        expanded?: false,
        children: [
          %{id: "conn_sqlite_logs", label: "logs", type: :table, expanded?: false, children: []}
        ]
      }
    ]

    app = App.new(sidebar_nodes: sample_nodes, selected_tree_node_id: "conn_pg")
    {:ok, app: app, sample_nodes: sample_nodes}
  end

  describe "Tree view node flattening" do
    test "flattens visible nodes according to expanded status", %{sample_nodes: nodes} do
      visible = Sidebar.flatten_visible_nodes(nodes, "conn_pg")

      labels = Enum.map(visible, & &1.label)
      assert labels == ["Prod Postgres", "public", "users", "orders", "Local SQLite"]

      # Check depth indentation
      depths = Enum.map(visible, & &1.depth)
      assert depths == [0, 1, 2, 2, 0]

      # Check selected node flag
      selected = Enum.find(visible, & &1.selected?)
      assert selected.id == "conn_pg"
    end

    test "collapsing a node hides its children", %{sample_nodes: nodes} do
      # Collapse public schema
      nodes_collapsed =
        update_in(nodes, [Access.at(0), :children, Access.at(0), :expanded?], fn _ -> false end)

      visible = Sidebar.flatten_visible_nodes(nodes_collapsed, "conn_pg")
      labels = Enum.map(visible, & &1.label)
      assert labels == ["Prod Postgres", "public", "Local SQLite"]
    end
  end

  describe "Keyboard navigation in tree view" do
    test "navigates down and up visible nodes", %{app: app} do
      assert app.selected_tree_node_id == "conn_pg"

      app = Sidebar.handle_key(app, :down)
      assert app.selected_tree_node_id == "conn_pg_public"

      app = Sidebar.handle_key(app, :down)
      assert app.selected_tree_node_id == "conn_pg_public_users"

      app = Sidebar.handle_key(app, :up)
      assert app.selected_tree_node_id == "conn_pg_public"
    end

    test "toggles node expand/collapse with right and left keys", %{app: app} do
      # Move selection to conn_sqlite (collapsed)
      app = Map.put(app, :selected_tree_node_id, "conn_sqlite")

      # Right expands collapsed node
      app = Sidebar.handle_key(app, :right)
      visible_after_expand = Sidebar.flatten_visible_nodes(app.sidebar_nodes, app.selected_tree_node_id)
      assert Enum.any?(visible_after_expand, &(&1.id == "conn_sqlite_logs"))

      # Left collapses expanded node
      app = Sidebar.handle_key(app, :left)
      visible_after_collapse = Sidebar.flatten_visible_nodes(app.sidebar_nodes, app.selected_tree_node_id)
      refute Enum.any?(visible_after_collapse, &(&1.id == "conn_sqlite_logs"))

      # Right on expanded node or leaf node switches focus to datagrid
      app_expanded = Sidebar.handle_key(app, :right)
      app_focused = Sidebar.handle_key(app_expanded, :right)
      assert app_focused.focus == :datagrid

      app_leaf = Map.put(app, :selected_tree_node_id, "conn_pg_public_users")
      app_leaf_focused = Sidebar.handle_key(app_leaf, :right)
      assert app_leaf_focused.focus == :datagrid
    end

    test "pressing enter on table node loads table data and switches to Table View", %{app: app} do
      app = Map.put(app, :selected_tree_node_id, "conn_pg_public_users")
      app = Sidebar.handle_key(app, :enter)

      assert app.active_view == :table_view
      assert app.selected_table == "users"
      assert app.datagrid_state != nil
      assert is_list(app.datagrid_state.columns)
    end
  end

  describe "Sidebar rendering" do
    test "renders tree component output for given area", %{app: app} do
      area = %{x: 0, y: 0, width: 30, height: 20}
      rendered = Sidebar.render(app, area)

      assert is_map(rendered)
      assert rendered.title == "CONNECTIONS / SCHEMA"
      assert rendered.area == area
      assert is_list(rendered.lines)
      assert length(rendered.lines) > 0
    end
  end
end
