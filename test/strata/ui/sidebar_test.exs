defmodule Strata.UI.Components.SidebarTest do
  use ExUnit.Case, async: true

  alias Strata.UI.App
  alias Strata.UI.Components.Sidebar

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
              %{
                id: "conn_pg_public_users",
                label: "users",
                type: :table,
                expanded?: false,
                children: []
              },
              %{
                id: "conn_pg_public_orders",
                label: "orders",
                type: :table,
                expanded?: false,
                children: []
              }
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

      visible_after_expand =
        Sidebar.flatten_visible_nodes(app.sidebar_nodes, app.selected_tree_node_id)

      assert Enum.any?(visible_after_expand, &(&1.id == "conn_sqlite_logs"))

      # Left collapses expanded node
      app = Sidebar.handle_key(app, :left)

      visible_after_collapse =
        Sidebar.flatten_visible_nodes(app.sidebar_nodes, app.selected_tree_node_id)

      refute Enum.any?(visible_after_collapse, &(&1.id == "conn_sqlite_logs"))

      # Right on expanded node or leaf node switches focus to datagrid
      app_expanded = Sidebar.handle_key(app, :right)
      app_focused = Sidebar.handle_key(app_expanded, :right)
      assert app_focused.focus == :datagrid

      app_leaf = Map.put(app, :selected_tree_node_id, "conn_pg_public_users")
      app_leaf_focused = Sidebar.handle_key(app_leaf, :right)
      assert app_leaf_focused.focus == :datagrid
    end

    test "pressing enter on table node loads table data, auto-focuses datagrid, and switches to Table View",
         %{app: app} do
      app = Map.put(app, :selected_tree_node_id, "conn_pg_public_users")
      app = Sidebar.handle_key(app, :enter)

      assert app.active_view == :table_view
      assert app.focus == :datagrid
      assert app.selected_table == "users"
      assert app.datagrid_state != nil
      assert is_list(app.datagrid_state.columns)
    end

    test "qualify_table quotes schema and table per driver" do
      assert Sidebar.qualify_table(:postgres, "users", "analytics") == ~s("analytics"."users")
      assert Sidebar.qualify_table(:mysql, "users", "mydb") == "`users`"
      assert Sidebar.qualify_table(:sqlite, "users", "main") == ~s("users")
    end

    test "collapses and expands all tree nodes with c and o keys", %{app: app} do
      # Press 'c' to collapse all
      app_collapsed = Sidebar.handle_key(app, "c")

      visible_c =
        Sidebar.flatten_visible_nodes(
          app_collapsed.sidebar_nodes,
          app_collapsed.selected_tree_node_id
        )

      assert length(visible_c) == 2

      # Press 'o' to expand all
      app_expanded = Sidebar.handle_key(app_collapsed, "o")

      visible_o =
        Sidebar.flatten_visible_nodes(
          app_expanded.sidebar_nodes,
          app_expanded.selected_tree_node_id
        )

      assert length(visible_o) > length(visible_c)
    end

    test "space key toggles node expansion", %{app: app} do
      app_sqlite = Map.put(app, :selected_tree_node_id, "conn_sqlite")
      app_toggled = Sidebar.handle_key(app_sqlite, :space)

      visible =
        Sidebar.flatten_visible_nodes(
          app_toggled.sidebar_nodes,
          app_toggled.selected_tree_node_id
        )

      assert Enum.any?(visible, &(&1.id == "conn_sqlite_logs"))
    end
  end

  describe "Sidebar rendering" do
    test "renders viewport tree component output for given area", %{app: app} do
      area = %{x: 0, y: 0, width: 30, height: 20}
      vp = Sidebar.render_viewport(app, area)

      assert is_map(vp)
      assert vp.title == "CONNECTIONS / SCHEMA"
      assert vp.viewport_h == 18
      assert length(vp.styled_items) > 0
    end

    test "filters tree nodes with / and renders search title", %{app: app} do
      filtered_app = %{app | sidebar_filter: "ord", sidebar_filter_active: true}
      vp = Sidebar.render_viewport(filtered_app, %{x: 0, y: 0, width: 30, height: 20})

      texts =
        Enum.map(vp.styled_items, fn line -> Enum.map_join(line.spans, "", & &1.content) end)

      assert vp.title == "CONNECTIONS / 🔍 ord▌"
      assert Enum.any?(texts, &String.contains?(&1, "orders"))
      refute Enum.any?(texts, &String.contains?(&1, "users"))
    end

    test "uses compact single-column glyphs, child counts, active table star, and styled lines",
         %{app: app} do
      active_app = %{
        app
        | selected_table: "users",
          connection_statuses: %{"conn_pg" => :connected}
      }

      vp = Sidebar.render_viewport(active_app, %{x: 0, y: 0, width: 30, height: 20})

      texts =
        Enum.map(vp.styled_items, fn line -> Enum.map_join(line.spans, "", & &1.content) end)

      assert Enum.any?(texts, &String.contains?(&1, "● Prod Postgres"))
      assert Enum.any?(texts, &String.contains?(&1, "▾ public (2)"))
      assert Enum.any?(texts, &String.contains?(&1, "▦ users"))
      refute Enum.any?(texts, &String.contains?(&1, "★"))
    end

    test "render_viewport slices and clamps scroll offset within bounds", %{app: app} do
      scrolled_app = %{
        app
        | sidebar_scroll_offset: 1,
          selected_tree_node_id: "conn_pg_public_users"
      }

      area = %{x: 0, y: 0, width: 30, height: 5}
      vp = Sidebar.render_viewport(scrolled_app, area)

      assert vp.viewport_h == 3
      assert vp.clamped_offset == 1
      assert vp.max_offset == vp.total - 3
      assert length(vp.styled_items) == 3
    end

    test "idle_node renders unconnected icon and hint instead of Loading schema" do
      profile = %Strata.ConnectionProfile{
        id: "idle_pg",
        name: "Prod PG",
        driver: :postgres,
        database: "app"
      }

      idle = Sidebar.idle_node(profile)
      assert idle.expanded? == false
      assert [%{id: "idle_pg_idle", label: "Not connected (Enter to connect)"}] = idle.children

      idle_app =
        App.new(sidebar_nodes: [%{idle | expanded?: true}], selected_tree_node_id: "idle_pg")

      vp = Sidebar.render_viewport(idle_app, %{x: 0, y: 0, width: 45, height: 10})

      texts =
        Enum.map(vp.styled_items, fn line -> Enum.map_join(line.spans, "", & &1.content) end)

      assert Enum.any?(texts, &String.contains?(&1, "○ 🐘 Prod PG"))
      assert Enum.any?(texts, &String.contains?(&1, "· Not connected (Enter to connect)"))
    end
  end
end
