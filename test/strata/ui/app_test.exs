defmodule Strata.UI.AppTest do
  use ExUnit.Case, async: true

  alias Strata.UI.App

  describe "App initialization" do
    test "initializes with default state" do
      app = App.new()

      assert app.focus == :sidebar
      assert app.modals == []
      assert app.mouse_enabled == true
      assert app.window_size == {120, 40}
      assert length(app.tabs) == 1
      assert app.active_tab_id != nil
    end

    test "initializes with custom options" do
      app = App.new(focus: :editor, window_size: {80, 24})

      assert app.focus == :editor
      assert app.window_size == {80, 24}
    end
  end

  describe "Focus management" do
    test "cycle_focus cycles through panes forward and backward" do
      app = App.new(focus: :sidebar, active_view: :query_view)

      app = App.cycle_focus(app, :next)
      assert app.focus == :editor

      app = App.cycle_focus(app, :next)
      assert app.focus == :datagrid

      app = App.cycle_focus(app, :next)
      assert app.focus == :sidebar

      app = App.cycle_focus(app, :prev)
      assert app.focus == :datagrid
    end

    test "set_focus sets specific pane if valid" do
      app = App.new()

      app = App.set_focus(app, :datagrid)
      assert app.focus == :datagrid

      app = App.set_focus(app, :invalid_pane)
      assert app.focus == :datagrid
    end
  end

  describe "Tab management" do
    test "opens, switches, and closes tabs" do
      app = App.new()
      initial_tab_id = app.active_tab_id

      app = App.open_tab(app, name: "Query 2", content: "SELECT 2;")
      assert length(app.tabs) == 2
      tab2_id = app.active_tab_id
      assert tab2_id != initial_tab_id

      app = App.switch_tab(app, initial_tab_id)
      assert app.active_tab_id == initial_tab_id

      app = App.close_tab(app, tab2_id)
      assert length(app.tabs) == 1
      assert app.active_tab_id == initial_tab_id
    end
  end

  describe "Modal stack management" do
    test "pushes and pops modals" do
      app = App.new()
      assert app.modals == []

      modal1 = Strata.UI.Components.ConnectionModal.new()
      app = App.push_modal(app, modal1)
      assert app.modals == [modal1]

      modal2 = Strata.UI.Components.ExportModal.new()
      app = App.push_modal(app, modal2)
      assert app.modals == [modal2, modal1]

      {popped, app} = App.pop_modal(app)
      assert popped == modal2
      assert app.modals == [modal1]

      {popped2, app} = App.pop_modal(app)
      assert popped2 == modal1
      assert app.modals == []
    end

    test "switches active_view mode between table_view and query_view" do
      app = App.new()
      assert app.active_view in [:query_view, :table_view]

      app = App.switch_view(app, :query_view)
      assert app.active_view == :query_view

      app = App.switch_view(app, :table_view)
      assert app.active_view == :table_view
    end
  end

  describe "Key event dispatching" do
    test "handles tab key to cycle focus" do
      app = App.new(focus: :sidebar, active_view: :query_view)

      app = App.handle_key(app, :tab)
      assert app.focus == :editor

      app = App.handle_key(app, :shift_tab)
      assert app.focus == :sidebar
    end

    test "handles ctrl+1..2 and 1..2 shortcuts for view mode switching" do
      app = App.new(active_view: :query_view, focus: :sidebar)
      app = App.load_table_async(app, "users")
      assert app.active_view == :table_view
      assert Enum.any?(app.tabs, &(&1.kind == :table and &1.table_name == "users"))

      app = App.handle_key(app, "2")
      assert app.active_view == :query_view

      app = App.handle_key(app, {:ctrl, "1"})
      assert app.active_view == :table_view

      app = App.handle_key(app, {:ctrl, "2"})
      assert app.active_view == :query_view
    end

    test "unified tabs isolate multiple tables, SQL queries + results, and tab bar clicks" do
      grid_a = Strata.UI.Components.DataGrid.new(["id"], [[1]])
      app = App.new(active_view: :table_view, selected_table: "users", datagrid_state: grid_a)
      assert length(app.tabs) == 1
      users_tab_id = app.active_tab_id

      # Opening a second table creates a new tab; reopening 'users' focuses existing tab
      app = App.load_table_async(app, "orders")
      assert length(app.tabs) == 2
      orders_tab_id = app.active_tab_id
      assert orders_tab_id != users_tab_id
      assert app.selected_table == "orders"

      app = App.load_table_async(app, "users")
      assert length(app.tabs) == 2
      assert app.active_tab_id == users_tab_id
      assert app.datagrid_state == grid_a

      # Opening a SQL editor tab creates a :query tab; query results stay inside that tab
      app = App.open_tab(app, name: "Query 1", content: "SELECT 42 AS answer;")
      assert length(app.tabs) == 3
      query_tab_id = app.active_tab_id
      assert app.active_view == :query_view
      assert app.datagrid_state == nil

      {:noreply, app} =
        App.handle_info(
          {:sql_query_finished, query_tab_id, 5, nil, false,
           {:ok, %{columns: ["answer"], rows: [[42]]}}},
          app
        )

      assert app.datagrid_state.rows == [[42]]

      # Switching back to 'users' preserves 'users' DataGrid, and switching back to Query 1 restores its results
      app = App.switch_tab(app, users_tab_id)
      assert app.datagrid_state == grid_a

      app = App.switch_tab(app, query_tab_id)
      assert app.datagrid_state.rows == [[42]]

      # Clicking tab bar [+ SQL] opens another SQL tab and clicking [×] closes a tab
      layout = Strata.UI.Renderer.layout(app.window_size, app.active_view)
      tb = Strata.UI.Renderer.tab_bar_layout(app, layout.tabs)
      app = App.handle_mouse(app, {:click, tb.new_sql_rect.x + 1, tb.new_sql_rect.y})
      assert length(app.tabs) == 4
      newest_id = app.active_tab_id

      tb2 = Strata.UI.Renderer.tab_bar_layout(app, layout.tabs)
      newest_item = Enum.find(tb2.tabs, &(&1.id == newest_id))
      app = App.handle_mouse(app, {:click, newest_item.close_rect.x, newest_item.close_rect.y})
      assert length(app.tabs) == 3
      refute Enum.any?(app.tabs, &(&1.id == newest_id))
    end

    test "handles escape to pop modal if active" do
      app = App.new()
      app = App.push_modal(app, %{type: :test_modal})
      assert length(app.modals) == 1

      app = App.handle_key(app, :esc)
      assert app.modals == []
    end
  end

  describe "Mouse event handling" do
    test "handles click inside pane bounds to switch focus" do
      app = App.new(focus: :sidebar, active_view: :query_view, window_size: {120, 40})

      # Click in right editor area (e.g. x: 50, y: 5)
      app = App.handle_mouse(app, {:click, 50, 5})
      assert app.focus == :editor
    end

    test "handles click on datagrid cell and selects correct row and column with column spacing" do
      cols = ["id", "name", "role", "status", "email"]

      rows = [
        [1, "Alice", "Admin", "Active", "alice@example.com"],
        [2, "Bob", "Developer", "Inactive", "bob@example.com"]
      ]

      grid = Strata.UI.Components.DataGrid.new(cols, rows)

      # Window size 120x40, table_view active (datagrid starts below tab bar at y: 1)
      app = App.new(active_view: :table_view, datagrid_state: grid, window_size: {120, 40})
      dg = Strata.UI.Renderer.layout({120, 40}, :table_view).datagrid

      # Column widths:
      # Col 0 ("id"): 5  -> rel_x: 0..4 (x: 31..35)
      # Col 1 ("name"): 8 -> rel_x: 6..13 (x: 37..44)
      # Col 2 ("role"): 12 -> rel_x: 15..26 (x: 46..57)
      # Col 3 ("status"): 11 -> rel_x: 28..38 (x: 59..69)
      # Col 4 ("email"): 20 -> rel_x: 40..59 (x: 71..90)

      # Click Col 0 ("id") row 0: x = 33, y = dg.y + 2
      a0 = App.handle_mouse(app, {:click, 33, dg.y + 2})
      assert a0.datagrid_state.selected_cell == {0, 0}

      # Click Col 1 ("name") row 0: x = 38, y = dg.y + 2
      a1 = App.handle_mouse(app, {:click, 38, dg.y + 2})
      assert a1.datagrid_state.selected_cell == {0, 1}

      # Click Col 2 ("role") row 0: x = 45, y = dg.y + 2
      a2 = App.handle_mouse(app, {:click, 45, dg.y + 2})
      assert a2.datagrid_state.selected_cell == {0, 2}

      # Click Col 3 ("status") row 1: x = 55, y = dg.y + 3
      a3 = App.handle_mouse(app, {:click, 55, dg.y + 3})
      assert a3.datagrid_state.selected_cell == {1, 3}

      # Click Col 4 ("email") row 1: x = 65, y = dg.y + 3
      a4 = App.handle_mouse(app, {:click, 65, dg.y + 3})
      assert a4.datagrid_state.selected_cell == {1, 4}
    end
  end

  describe "SQL Query execution and tab shortcuts" do
    test "execute_sql_query warns when SQL is empty" do
      app = App.new()
      app = App.execute_sql_query(app)

      assert app.status_message =~ "empty SQL query"
    end

    test "Ctrl+T and Ctrl+W manage editor tabs" do
      app = App.new()
      assert length(app.tabs) == 1

      app = App.handle_key(app, {:ctrl, "t"})
      assert length(app.tabs) == 2

      app = App.handle_key(app, {:ctrl, "w"})
      assert length(app.tabs) == 1
    end

    test "Ctrl+Enter and Ctrl+R trigger execute_sql_query" do
      app = App.new(focus: :editor)
      app = App.handle_key(app, {:ctrl, "enter"})
      assert app.status_message =~ "empty SQL query"

      app = App.handle_key(app, {:ctrl, "r"})
      assert app.status_message =~ "empty SQL query"
    end

    test "App.handle_key applies suggestion on Enter or Tab when popup is open, and cycles focus on Tab when closed" do
      app =
        App.new(focus: :editor)
        |> App.handle_key("S")
        |> App.handle_key("E")

      active = Enum.find(app.tabs, &(&1.id == app.active_tab_id))
      assert active.completion.active? == true

      # Enter applies first suggestion through full App.handle_key dispatch
      entered = App.handle_key(app, :enter)
      entered_tab = Enum.find(entered.tabs, &(&1.id == entered.active_tab_id))
      assert entered_tab.content == "SELECT"
      assert entered_tab.completion.active? == false
      assert entered.focus == :editor

      # Tab also applies selected suggestion when popup is open without leaving :editor
      tabbed = app |> App.handle_key(:down) |> App.handle_key(:tab)
      tabbed_tab = Enum.find(tabbed.tabs, &(&1.id == tabbed.active_tab_id))
      assert tabbed_tab.content == "SET"
      assert tabbed_tab.completion.active? == false
      assert tabbed.focus == :editor

      # Tab when completion popup is closed still cycles pane focus
      cycled = App.handle_key(tabbed, :tab)
      assert cycled.focus == :datagrid
    end

    test "columns_prefetched populates DataStore and Ctrl+Space suggests alias columns in App" do
      pid = "prefetch_conn_#{System.unique_integer([:positive])}"
      app = App.new(focus: :editor) |> put_in([Access.key(:tabs), Access.at(0), :profile_id], pid)

      {:noreply, app, render?: false} =
        App.handle_info(
          {:columns_prefetched, pid, {:ok, [{"public", "users", ["id", "email"]}]}},
          app
        )

      app =
        app
        |> put_in([Access.key(:tabs), Access.at(0), :content], "SELECT * FROM users u WHERE ")
        |> put_in([Access.key(:tabs), Access.at(0), :cursor], {0, 28})
        |> App.handle_key({:ctrl, "space"})

      active = Enum.find(app.tabs, &(&1.id == app.active_tab_id))
      assert active.completion.active? == true
      assert Enum.any?(active.completion.suggestions, &(&1.insert_text == "u.email"))
    end

    test "Esc in editor focus dismisses completion popup first, then moves focus to datagrid" do
      app =
        App.new(focus: :editor)
        |> App.handle_key("S")
        |> App.handle_key("E")

      active = Enum.find(app.tabs, &(&1.id == app.active_tab_id))
      assert active.completion.active? == true

      # First Esc closes completion popup while staying in editor focus
      app = App.handle_key(app, :esc)
      active_after = Enum.find(app.tabs, &(&1.id == app.active_tab_id))
      assert active_after.completion.active? == false
      assert app.focus == :editor

      # Second Esc moves focus out of editor to datagrid
      app = App.handle_key(app, :esc)
      assert app.focus == :datagrid
    end

    test "mouse wheel scrolls SQL editor independently and click inside scrolled editor maps accurately" do
      long_sql = Enum.map_join(1..30, "\n", fn i -> "SELECT #{i} AS col_#{i};" end)

      app =
        App.new(window_size: {120, 30}, active_view: :query_view, focus: :editor)
        |> put_in([Access.key(:tabs), Access.at(0), :content], long_sql)
        |> put_in([Access.key(:tabs), Access.at(0), :cursor], {0, 0})

      layout = Strata.UI.Renderer.layout(app.window_size, :query_view)
      ed = layout.editor

      # Scroll down over SQL editor
      app = App.handle_mouse(app, {:scroll, :scroll_down, ed.x + 2, ed.y + 2})
      active = Enum.find(app.tabs, &(&1.id == app.active_tab_id))
      assert active.scroll_offset == 3
      assert active.cursor == {0, 0}

      # Clicking first visible code line lands at logical row 3 (scrolled offset + 0)
      app = App.handle_mouse(app, {:click, ed.x + 10, ed.y + 1})
      active_clicked = Enum.find(app.tabs, &(&1.id == app.active_tab_id))
      assert elem(active_clicked.cursor, 0) == 3

      # Scroll back up
      app = %{app | scroll_lock: nil}
      app = App.handle_mouse(app, {:scroll, :scroll_up, ed.x + 2, ed.y + 2})
      active_up = Enum.find(app.tabs, &(&1.id == app.active_tab_id))
      assert active_up.scroll_offset == 0
    end

    test "clicking any cell in tab close_rect [×] closes even :table tabs" do
      table_tab = %{
        id: "tab_tbl",
        kind: :table,
        name: "users",
        table_name: "users",
        datagrid_state: nil
      }

      query_tab = %{
        id: "tab_q",
        kind: :query,
        name: "Query 1",
        content: "",
        cursor: {0, 0},
        datagrid_state: nil
      }

      app =
        App.new(
          window_size: {120, 30},
          tabs: [table_tab, query_tab],
          active_tab_id: "tab_tbl",
          active_view: :table_view
        )

      layout = Strata.UI.Renderer.layout(app.window_size, app.active_view)
      tb = Strata.UI.Renderer.tab_bar_layout(app, layout.tabs)
      tbl_item = Enum.find(tb.tabs, &(&1.id == "tab_tbl"))
      assert tbl_item.close_rect.width == 3

      # Clicking middle ('×') and right edge (']') of [×] both close the table tab
      app_mid =
        App.handle_mouse(app, {:click, tbl_item.close_rect.x + 1, tbl_item.close_rect.y})

      assert Enum.map(app_mid.tabs, & &1.id) == ["tab_q"]

      app_right =
        App.handle_mouse(app, {:click, tbl_item.close_rect.x + 2, tbl_item.close_rect.y})

      assert Enum.map(app_right.tabs, & &1.id) == ["tab_q"]
    end

    test "query result pagination loads next chunk on scroll near bottom and handles query_chunk_loaded" do
      prof = %Strata.ConnectionProfile{
        id: "q_page_conn_#{System.unique_integer([:positive])}",
        name: "Query Page SQLite",
        driver: :sqlite,
        database: ":memory:"
      }

      :ok = Strata.ConfigStore.put_profile(prof)
      on_exit(fn -> Strata.ConfigStore.delete_profile(prof.id) end)

      rows_100 = Enum.map(1..100, fn i -> [i, "Row #{i}"] end)

      grid =
        Strata.UI.Components.DataGrid.new(["id", "name"], rows_100,
          has_more: true,
          loading_more: false,
          batch_size: 100
        )

      app =
        App.new(active_view: :query_view, focus: :datagrid)
        |> put_in([Access.key(:tabs), Access.at(0), :profile_id], prof.id)
        |> put_in([Access.key(:tabs), Access.at(0), :executed_sql], "SELECT * FROM items")
        |> put_in([Access.key(:tabs), Access.at(0), :query_request_id], 77)
        |> Map.put(:datagrid_state, grid)

      # Jump to bottom in datagrid -> triggers load_more_query_data
      app = App.handle_key(app, :end)
      assert app.datagrid_state.loading_more == true
      assert app.status_message == "Loading more query rows..."

      # Receive second batch -> appends rows and updates has_more
      {:noreply, app} =
        App.handle_info(
          {:query_chunk_loaded, app.active_tab_id, 77, 100,
           {:ok, %{rows: [[101, "Row 101"]], has_more: false}}},
          app
        )

      assert length(app.datagrid_state.rows) == 101
      assert app.datagrid_state.has_more == false
      assert app.datagrid_state.loading_more == false
    end
  end

  describe "Table view load_more_table_data & infinite scroll" do
    test "load_more_table_data triggers async Task and updates state via handle_info" do
      prof = %Strata.ConnectionProfile{
        id: "load_more_conn_#{System.unique_integer([:positive])}",
        name: "Load More SQLite",
        driver: :sqlite,
        database: ":memory:"
      }

      :ok = Strata.ConfigStore.put_profile(prof)

      on_exit(fn ->
        Strata.ConfigStore.delete_profile(prof.id)
      end)

      grid =
        Strata.UI.Components.DataGrid.new(["id", "name"], [[1, "User 1"]],
          has_more: true,
          loading_more: false
        )

      app =
        App.new(
          active_view: :table_view,
          selected_table: "users",
          selected_tree_node_id: "#{prof.id}_table_users",
          datagrid_state: grid
        )

      updated = App.load_more_table_data(app)

      assert updated.datagrid_state.loading_more == true
      assert updated.status_message =~ "Loading more rows"

      # Simulate receiving async chunk loaded message
      fake_result = {:ok, ["id", "name"], [[2, "User 2"]]}

      {:noreply, final_state} =
        App.handle_info(
          {:table_chunk_loaded, updated.active_tab_id, "users", 1, fake_result},
          updated
        )

      assert final_state.datagrid_state.loading_more == false
      assert length(final_state.datagrid_state.rows) == 2
      assert final_state.status_message =~ "Loaded +1 rows"
    end

    test "load_more_table_data ignores request if has_more is false or loading_more is true" do
      grid =
        Strata.UI.Components.DataGrid.new(["id", "name"], [[1, "User 1"]],
          has_more: false,
          loading_more: false
        )

      app =
        App.new(
          active_view: :table_view,
          selected_table: "users",
          datagrid_state: grid
        )

      assert App.load_more_table_data(app) == app

      grid_loading = %{grid | has_more: true, loading_more: true}
      app_loading = %{app | datagrid_state: grid_loading}
      assert App.load_more_table_data(app_loading) == app_loading
    end
  end

  describe "Modal scroll lock, outside-click dismiss, and async query/table flows" do
    test "locks background scroll and dismisses modal on outside click" do
      grid = Strata.UI.Components.DataGrid.new(["id"], Enum.map(1..50, &[&1]))

      app =
        App.new(active_view: :table_view, datagrid_state: grid, window_size: {120, 40})
        |> App.push_modal(Strata.UI.Components.ExportModal.new())

      # Scroll inside datagrid area should be ignored while modal is open
      after_scroll = App.handle_mouse(app, {:scroll, :down, 50, 10})
      assert after_scroll.datagrid_state.scroll_offset == 0
      assert length(after_scroll.modals) == 1

      # Click outside modal bounds (x=0, y=0) dismisses modal
      after_outside_click = App.handle_mouse(after_scroll, {:click, 0, 0})
      assert after_outside_click.modals == []
    end

    test "handles async sql_query_finished and preserves raw cell types" do
      app = App.new(focus: :editor)
      result = {:ok, %{columns: ["id", "meta", "empty"], rows: [[1, %{"ok" => true}, nil]]}}

      {:noreply, updated} =
        App.handle_info({:sql_query_finished, app.active_tab_id, 5, nil, false, result}, app)

      assert updated.active_view == :query_view
      assert updated.datagrid_state.rows == [[1, %{"ok" => true}, nil]]
      assert updated.status_message =~ "1 rows in 5ms"
    end

    test "KeyRegistry determines UI context accurately and Cache bounds entries" do
      assert Strata.UI.KeyRegistry.determine_context(App.new(focus: :sidebar)) == :sidebar
      assert Strata.UI.KeyRegistry.determine_context(App.new(focus: :editor)) == :editor

      app_modal = App.new() |> App.push_modal(Strata.UI.Components.ConnectionModal.new())
      assert Strata.UI.KeyRegistry.determine_context(app_modal) == :modal

      assert 42 == Strata.UI.Cache.fetch(:test_ns, :k1, 2, fn -> 42 end)
      assert 42 == Strata.UI.Cache.fetch(:test_ns, :k1, 2, fn -> 99 end)
    end

    test "load_table_async auto-focuses datagrid, ignores stale request_id, and hits DataStore cache" do
      prof = %Strata.ConnectionProfile{
        id: "async_conn_#{System.unique_integer([:positive])}",
        name: "Async SQLite",
        driver: :sqlite,
        database: ":memory:"
      }

      :ok = Strata.ConfigStore.put_profile(prof)

      on_exit(fn ->
        Strata.ConfigStore.delete_profile(prof.id)
        Strata.DataStore.invalidate_connection_cache(prof.id)
      end)

      nodes = [
        %{
          id: prof.id,
          label: "Async SQLite",
          type: :connection,
          expanded?: true,
          children: [
            %{
              id: "#{prof.id}_schema_main",
              label: "main",
              type: :schema,
              expanded?: true,
              children: [
                %{
                  id: "#{prof.id}_main_tbl_accounts",
                  label: "accounts",
                  type: :table,
                  schema: "main",
                  children: []
                }
              ]
            }
          ]
        }
      ]

      app = App.new(sidebar_nodes: nodes, selected_tree_node_id: "#{prof.id}_main_tbl_accounts")
      loading_app = App.load_table_async(app, "accounts")

      assert loading_app.focus == :datagrid
      assert loading_app.active_view == :table_view
      assert loading_app.selected_schema == "main"
      assert is_integer(loading_app.table_request_id)

      # Stale response with wrong request_id is ignored
      {:noreply, still_loading} =
        App.handle_info(
          {:table_data_loaded, -1, prof.id, "main", "accounts", {:ok, ["id"], [[999]]}},
          loading_app
        )

      assert still_loading.datagrid_state.loading_more == true

      # Matching request_id populates grid and caches in DataStore
      {:noreply, loaded_app} =
        App.handle_info(
          {:table_data_loaded, loading_app.table_request_id, prof.id, "main", "accounts",
           {:ok, ["id"], [[1], [2]]}},
          loading_app
        )

      assert loaded_app.datagrid_state.rows == [[1], [2]]
      assert loaded_app.status_message =~ "[DB]"

      # Re-opening already open table focuses existing tab
      focused_app = App.load_table_async(loaded_app, "accounts")
      assert focused_app.status_message =~ "Switched to tab 'accounts'"
      assert focused_app.datagrid_state.rows == [[1], [2]]

      # Closing tab and reopening 'accounts' serves instantly from DataStore cache
      closed_app = App.close_tab(loaded_app, loaded_app.active_tab_id)
      cached_app = App.load_table_async(closed_app, "accounts")
      assert cached_app.status_message =~ "[Cache]"
      assert cached_app.datagrid_state.rows == [[1], [2]]
    end

    test "handles async connection_test_finished and filter_query_finished messages" do
      cm = Strata.UI.Components.ConnectionModal.new(status: :testing)
      app = App.new() |> App.push_modal(cm)

      {:noreply, ok_app} = App.handle_info({:connection_test_finished, :ok}, app)
      assert hd(ok_app.modals).status == :ok

      err_app_in =
        App.new() |> App.push_modal(Strata.UI.Components.ConnectionModal.new(status: :testing))

      {:noreply, err_app} =
        App.handle_info(
          {:connection_test_finished,
           {:error,
            %DBConnection.ConnectionError{
              message: "tcp connect (127.0.0.1:5432): connection refused - :econnrefused"
            }}},
          err_app_in
        )

      assert hd(err_app.modals).status == :error

      assert hd(err_app.modals).status_message ==
               "❌ Connection failed: tcp connect (127.0.0.1:5432): connection refused - :econnrefused"

      app_f = App.new()

      {:noreply, filtered_app} =
        App.handle_info(
          {:filter_query_finished, app_f.active_tab_id, "id > 0", "",
           {:ok, %{columns: ["id"], rows: [[10]]}}},
          app_f
        )

      assert filtered_app.datagrid_state.rows == [[10]]
      assert filtered_app.status_message =~ "Filter applied (1 rows)"
    end

    test "allows typing 'q' and 'Q' in editor and modals while quitting in navigation mode" do
      editor_app = App.new(focus: :editor)

      {:noreply, after_q} =
        App.handle_event(%ExRatatui.Event.Key{code: "q", modifiers: []}, editor_app)

      assert hd(after_q.tabs).content == "q"

      modal_app =
        App.new()
        |> App.push_modal(
          Strata.UI.Components.ConnectionModal.new(name: "", focused_field: :name)
        )

      {:noreply, after_modal_q} =
        App.handle_event(%ExRatatui.Event.Key{code: "q", modifiers: []}, modal_app)

      assert hd(after_modal_q.modals).name == "q"

      nav_app = App.new(focus: :sidebar)

      assert {:stop, ^nav_app} =
               App.handle_event(%ExRatatui.Event.Key{code: "q", modifiers: []}, nav_app)
    end

    test "opens Right Inspector only on double-click within threshold and supports editor click cursor" do
      grid = Strata.UI.Components.DataGrid.new(["id", "name"], [[1, "Alice"]])
      app = App.new(active_view: :table_view, datagrid_state: grid, window_size: {120, 40})
      dg = Strata.UI.Renderer.layout({120, 40}, :table_view).datagrid

      # First click selects cell
      clicked1 = App.handle_mouse(app, {:click, 33, dg.y + 2})
      assert clicked1.datagrid_state.selected_cell == {0, 0}
      assert clicked1.modals == []
      assert clicked1.inspector_open == false

      # Immediate second click opens Right Inspector Drawer
      clicked2 = App.handle_mouse(clicked1, {:click, 33, dg.y + 2})
      assert clicked2.modals == []
      assert clicked2.inspector_open == true

      # Stale timestamp (> 500ms ago) on same cell does not open inspector
      stale = %{clicked1 | last_grid_click: {{0, 0}, System.monotonic_time(:millisecond) - 1000}}
      clicked_stale = App.handle_mouse(stale, {:click, 33, dg.y + 2})
      assert clicked_stale.modals == []
      assert clicked_stale.inspector_open == false

      # Clicking inside SQL Editor places cursor on clicked row/col
      query_app =
        App.new(active_view: :query_view, window_size: {120, 40})
        |> put_in([Access.key(:tabs), Access.at(0), :content], "SELECT *\nFROM users")

      layout = Strata.UI.Renderer.layout({120, 40}, :query_view)
      placed = App.handle_mouse(query_app, {:click, layout.editor.x + 10, layout.editor.y + 2})
      assert placed.focus == :editor
      assert hd(placed.tabs).cursor == {1, 3}
    end

    test "supports ActionsModal, header sort, inline TextInput edit, Structure toggle, and SQLite commit" do
      prof = %Strata.ConnectionProfile{
        id: "edit_sqlite_#{System.unique_integer([:positive])}",
        name: "Editable SQLite",
        driver: :sqlite,
        database: ":memory:"
      }

      :ok = Strata.ConfigStore.put_profile(prof)

      on_exit(fn ->
        Strata.ConnectionSupervisor.stop_worker(prof.id)
        Strata.ConfigStore.delete_profile(prof.id)
        Strata.DataStore.invalidate_connection_cache(prof.id)
      end)

      assert {:ok, _} =
               Strata.ConnectionWorker.execute_query_for_profile(
                 prof,
                 "CREATE TABLE items (id INTEGER PRIMARY KEY, label TEXT)"
               )

      assert {:ok, _} =
               Strata.ConnectionWorker.execute_query_for_profile(
                 prof,
                 "INSERT INTO items VALUES (1, 'Alpha'), (2, 'Beta')"
               )

      nodes = [
        %{
          id: prof.id,
          label: "Editable SQLite",
          type: :connection,
          expanded?: true,
          children: [
            %{
              id: "#{prof.id}_schema_main",
              label: "main",
              type: :schema,
              expanded?: true,
              children: [
                %{
                  id: "#{prof.id}_main_tbl_items",
                  label: "items",
                  type: :table,
                  schema: "main",
                  children: []
                }
              ]
            }
          ]
        }
      ]

      grid =
        Strata.UI.Components.DataGrid.new(["id", "label"], [[1, "Alpha"], [2, "Beta"]],
          primary_keys: ["id"],
          mode: :selecting,
          selected_cell: {0, 1}
        )

      app =
        App.new(
          focus: :datagrid,
          active_view: :table_view,
          selected_table: "items",
          selected_schema: "main",
          sidebar_nodes: nodes,
          selected_tree_node_id: "#{prof.id}_main_tbl_items",
          datagrid_state: grid,
          window_size: {120, 40}
        )

      # '?' opens ActionsModal and 'Esc' closes it
      with_actions = App.handle_key(app, "?")
      assert match?([%Strata.UI.Components.ActionsModal{}], with_actions.modals)
      closed_actions = App.handle_key(with_actions, :esc)
      assert closed_actions.modals == []

      # Inline cell edit using ExRatatui.Widgets.TextInput NIF + Enter stage
      editing_app = App.handle_key(app, "e")
      assert editing_app.datagrid_state.editing_cell == {0, 1}
      refute is_nil(editing_app.inline_input_ref)

      editing_app =
        editing_app
        |> App.handle_key("!")
        |> App.handle_key(:enter)

      assert editing_app.datagrid_state.editing_cell == nil
      assert editing_app.inline_input_ref == nil
      assert editing_app.datagrid_state.pending_edits[{0, 1}] == %{orig: "Alpha", new: "Alpha!"}

      # Commit staged changes to SQLite DB inside transaction
      committing_app = App.handle_key(editing_app, {:ctrl, "s"})
      assert committing_app.status_message =~ "Committing"

      assert_receive {:commit_finished, _req_id, _pid, _schema, "items", {:ok, 1}}, 2_000

      assert {:ok, %{rows: [[1, "Alpha!"], [2, "Beta"]]}} =
               Strata.ConnectionWorker.execute_query_for_profile(
                 prof,
                 "SELECT id, label FROM items ORDER BY id"
               )

      # Toggle Data <-> Structure view and inspect schema columns synchronously on cache miss/receive
      toggled = App.handle_key(app, :f3)
      assert toggled.datagrid_state.view_mode == :structure
      assert_receive {:structure_view_loaded, req_id, pid, schema, "items", res}, 2_000

      {:noreply, struct_loaded} =
        App.handle_info({:structure_view_loaded, req_id, pid, schema, "items", res}, toggled)

      assert struct_loaded.datagrid_state.view_mode == :structure
      assert Enum.map(struct_loaded.datagrid_state.rows, &hd/1) == ["id", "label"]

      back_to_data = App.handle_key(struct_loaded, "s")
      assert back_to_data.datagrid_state.view_mode == :data
      assert back_to_data.datagrid_state.rows == [[1, "Alpha"], [2, "Beta"]]

      # Clicking column header row sorts active rows in memory when offline
      offline_app =
        App.new(
          focus: :datagrid,
          active_view: :query_view,
          datagrid_state: grid,
          window_size: {120, 40}
        )

      layout = Strata.UI.Renderer.layout({120, 40}, :query_view)

      sorted_click =
        App.handle_mouse(offline_app, {:click, layout.datagrid.x + 2, layout.datagrid.y + 1})

      assert sorted_click.datagrid_state.sort_by == {"id", :asc}

      # Sort is blocked when dirty staged edits exist so row indices stay aligned
      dirty_app = %{
        offline_app
        | datagrid_state: Strata.UI.Components.DataGrid.stage_cell_edit(grid, 0, 1, "Dirty")
      }

      blocked_sort = App.sort_active_table_by_col(dirty_app, 0)
      assert blocked_sort.datagrid_state.sort_by == nil
      assert blocked_sort.status_message =~ "Commit (Ctrl+S) or Revert (Ctrl+Z)"

      # Clicking grid while inline edit is open cancels editing_cell cleanly
      active_edit = App.start_inline_edit(offline_app)
      assert active_edit.datagrid_state.editing_cell != nil

      after_click_away =
        App.handle_mouse(active_edit, {:click, layout.datagrid.x + 2, layout.datagrid.y + 3})

      assert after_click_away.datagrid_state.editing_cell == nil
      assert after_click_away.inline_input_ref == nil

      # Footer clickable [Ctrl+N] triggers NULL staging during inline edit
      editing_again = App.start_inline_edit(offline_app)
      footer_actions = Strata.UI.Components.Footer.clickable_actions(editing_again, layout.footer)
      null_btn = Enum.find(footer_actions, &(&1.key == :"ctrl+n"))
      refute is_nil(null_btn)

      after_null_click =
        App.handle_mouse(editing_again, {:click, null_btn.area.x, null_btn.area.y})

      assert after_null_click.datagrid_state.editing_cell == nil
      assert after_null_click.datagrid_state.pending_edits[{0, 1}] == %{orig: "Alpha", new: nil}
    end

    test "supports Event.Paste and Ctrl+V across modals, inline TextInput, grid cells, and preserves active_filter" do
      grid =
        Strata.UI.Components.DataGrid.new(["id", "name"], [[1, "Alice"], [2, "Bob"]],
          mode: :selecting,
          selected_cell: {0, 1}
        )

      # 1. Bracketed Event.Paste into Unified Filter & Sort Bar
      filter_app =
        App.new(focus: :datagrid, datagrid_state: grid)
        |> App.open_filter_bar()

      {:noreply, pasted_filter_app} =
        App.handle_event(%ExRatatui.Event.Paste{content: "Alice\n"}, filter_app)

      assert pasted_filter_app.filter_bar_text == "Alice"

      # 2. Bracketed Event.Paste into ConnectionModal
      conn_app =
        App.new()
        |> App.push_modal(
          Strata.UI.Components.ConnectionModal.new(host: "", focused_field: :host)
        )

      {:noreply, pasted_conn_app} =
        App.handle_event(%ExRatatui.Event.Paste{content: "db.internal.local\n"}, conn_app)

      assert hd(pasted_conn_app.modals).host == "db.internal.local"

      # 3. Ctrl+V paste via Strata.Clipboard into inline cell TextInput and selected cell
      :ok = Strata.Clipboard.copy("ClipboardVal")
      assert {:ok, "ClipboardVal"} = Strata.Clipboard.paste()

      inline_app =
        App.new(focus: :datagrid, active_view: :query_view, datagrid_state: grid)
        |> App.start_inline_edit()

      {:noreply, pasted_inline_app} =
        App.handle_event(%ExRatatui.Event.Key{code: "v", modifiers: ["ctrl"]}, inline_app)

      assert ExRatatui.text_input_get_value(pasted_inline_app.inline_input_ref) ==
               "AliceClipboardVal"

      # Ctrl+V on selected cell without inline editor open stages clipboard directly
      selecting_app = App.new(focus: :datagrid, active_view: :query_view, datagrid_state: grid)

      {:noreply, pasted_cell_app} =
        App.handle_event(%ExRatatui.Event.Key{code: "v", modifiers: ["ctrl"]}, selecting_app)

      assert pasted_cell_app.datagrid_state.pending_edits[{0, 1}] == %{
               orig: "Alice",
               new: "ClipboardVal"
             }

      # 4. Applying filter stores active_filter and re-opening Filter Bar restores it
      applied_app = App.handle_key(pasted_filter_app, :enter)

      assert applied_app.active_filter == %{
               mode: :builder,
               column: "name",
               op: :contains,
               value: "Alice",
               summary: "name contains Alice"
             }

      reopened_app = App.open_filter_bar(applied_app)
      assert reopened_app.filter_bar_col == "name"
      assert reopened_app.filter_bar_text == "Alice"

      # Clearing filter with Ctrl+L resets active_filter
      cleared_app = App.handle_key(reopened_app, {:ctrl, "l"})
      assert cleared_app.active_filter == nil
      assert cleared_app.filter_bar_open == false
    end

    test "supports Visual Smart Filter Bar (* All, Col/Op/Val, Shift+F 1-click, SQL toggle) and Right Inspector Drawer" do
      grid =
        Strata.UI.Components.DataGrid.new(
          ["id", "name", "meta"],
          [[1, "Alice", ~s({"role":"admin"})], [2, "Bob", ~s({"role":"user"})]],
          mode: :selecting,
          selected_cell: {0, 1}
        )

      app =
        App.new(
          focus: :datagrid,
          active_view: :table_view,
          selected_table: "users",
          datagrid_state: grid,
          window_size: {120, 40}
        )

      # Pressing '/' opens Quick Search across '* All' columns
      quick_open = App.handle_key(app, "/")
      assert quick_open.filter_bar_open == true
      assert quick_open.filter_bar_focused == true
      assert quick_open.filter_bar_col == "* All"
      assert quick_open.filter_bar_op == :contains
      assert Strata.UI.KeyRegistry.determine_context(quick_open) == :filter_bar

      # Paste keyword without SQL syntax and Enter applies filter & returns focus to grid
      {:noreply, pasted_bar} =
        App.handle_event(%ExRatatui.Event.Paste{content: "Alice\n"}, quick_open)

      assert pasted_bar.filter_bar_text == "Alice"

      applied_bar = App.handle_key(pasted_bar, :enter)
      assert applied_bar.filter_bar_focused == false

      assert applied_bar.active_filter == %{
               mode: :builder,
               column: "* All",
               op: :contains,
               value: "Alice",
               summary: "* All contains Alice"
             }

      # Ctrl+L clears active filter and closes bar
      cleared_bar = App.handle_key(applied_bar, {:ctrl, "l"})
      assert cleared_bar.active_filter == nil
      assert cleared_bar.filter_bar_open == false

      # Pressing 'f' in Select mode pre-selects current column; Tab/Right/Ctrl+R and Visual Dropdown work
      col_open = App.handle_key(app, "f")
      assert col_open.filter_bar_col == "name"
      assert col_open.filter_bar_focus_part == :value

      on_col = col_open |> App.handle_key(:shift_tab) |> App.handle_key(:shift_tab)
      assert on_col.filter_bar_focus_part == :column
      cycled_col = App.handle_key(on_col, :right)
      assert cycled_col.filter_bar_col == "meta"

      # Pressing Down/Enter on :column opens visual searchable Column Dropdown
      col_dd = App.handle_key(cycled_col, :down)
      assert col_dd.filter_dropdown == :column
      searched_dd = App.handle_key(col_dd, "n")
      assert searched_dd.filter_dropdown_search == "n"
      picked_col = App.handle_key(searched_dd, :enter)
      assert picked_col.filter_bar_col == "name"
      assert picked_col.filter_dropdown == nil
      assert picked_col.filter_bar_focus_part == :value

      on_op = App.handle_key(picked_col, :shift_tab)
      assert on_op.filter_bar_focus_part == :op
      cycled_op = App.handle_key(on_op, :right)
      assert cycled_op.filter_bar_op == :starts_with

      # Unified Filter & Sort Bar exposes Sort pill without Raw SQL mode toggle
      layout = Strata.UI.Renderer.layout({120, 40}, :table_view)
      areas = Strata.UI.Renderer.datagrid_areas(layout.datagrid, col_open)
      rects = Strata.UI.Renderer.filter_bar_rects(areas.filter_area, col_open)
      refute Map.has_key?(rects, :mode_rect)
      assert Map.has_key?(rects, :sort_rect)

      # Clicking [Sort ▾] opens unified Sort dropdown
      sort_dd_app = App.handle_mouse(col_open, {:click, rects.sort_rect.x, rects.sort_rect.y})
      assert sort_dd_app.filter_dropdown == :sort

      closed_no_reload =
        App.handle_mouse(col_open, {:click, rects.clear_rect.x, rects.clear_rect.y})

      assert closed_no_reload.filter_bar_open == false
      assert closed_no_reload.datagrid_state.loading_more == false
      assert closed_no_reload.status_message == "Filter bar closed"

      # Shift+F ('F') in Select mode applies immediate 1-click filter by active cell value
      one_click = App.handle_key(app, "F")

      assert one_click.active_filter == %{
               mode: :builder,
               column: "name",
               op: :=,
               value: "Alice",
               summary: "name = Alice"
             }

      # Pressing Enter in Select Mode opens Right Inspector Drawer (and 'I' / Esc toggles it)
      inspected = App.handle_key(app, :enter)
      assert inspected.inspector_open == true

      # Moving selection down keeps Inspector open for live row/cell tracking
      moved = App.handle_key(inspected, :down)
      assert moved.inspector_open == true
      assert moved.datagrid_state.selected_cell == {1, 1}

      # Pressing Esc while selecting + Inspector open closes Inspector first, keeping :selecting
      esc_once = App.handle_key(moved, :esc)
      assert esc_once.inspector_open == false
      assert esc_once.datagrid_state.mode == :selecting

      # Pressing Esc a second time exits Select Mode to :browsing
      esc_twice = App.handle_key(esc_once, :esc)
      assert esc_twice.datagrid_state.mode == :browsing

      # Pressing 'I' toggles Inspector Drawer off cleanly
      closed_insp = App.handle_key(moved, "I")
      assert closed_insp.inspector_open == false
    end

    test "splits Inspector into independently scrollable Data Field and Row Summary panes with JSON highlighting" do
      long_json =
        Jason.encode!(%{
          "items" =>
            Enum.map(1..20, fn i ->
              %{"id" => i, "name" => "Item #{i}", "active" => rem(i, 2) == 0}
            end)
        })

      cols = Enum.map(1..16, fn i -> "col_#{i}" end)
      row = [long_json | Enum.map(2..16, fn i -> "val_#{i}" end)]

      grid =
        Strata.UI.Components.DataGrid.new(cols, [row, Enum.map(1..16, fn i -> "b_#{i}" end)],
          mode: :selecting,
          selected_cell: {0, 0}
        )

      app =
        App.new(
          window_size: {120, 30},
          active_view: :table_view,
          focus: :datagrid,
          datagrid_state: grid
        )
        |> App.open_inspector()

      layout = Strata.UI.Renderer.layout({120, 30}, :table_view)
      %{inspector_area: i_area} = Strata.UI.Renderer.datagrid_areas(layout.datagrid, app)
      %{value_area: v_area, summary_area: s_area} = Strata.UI.Renderer.inspector_areas(i_area)
      assert v_area.height + s_area.height == i_area.height

      # Scroll Data Field pane independently via mouse wheel (3-line Table-View-matched step) and keyboard
      scrolled_val = App.handle_mouse(app, {:scroll, :down, v_area.x + 2, v_area.y + 2})
      assert scrolled_val.inspector_value_scroll == 3
      assert scrolled_val.inspector_summary_scroll == 0
      assert scrolled_val.datagrid_state.scroll_offset == 0

      # Horizontal trackpad jitter inside Inspector must not bounce vertical scroll
      ignored_h = App.handle_mouse(scrolled_val, {:scroll, :left, v_area.x + 2, v_area.y + 2})
      assert ignored_h.inspector_value_scroll == 3

      scrolled_val_key = App.handle_key(scrolled_val, "]")
      assert scrolled_val_key.inspector_value_scroll == 5

      # Scroll Row Summary pane independently via mouse wheel and keyboard
      scrolled_sum =
        App.handle_mouse(scrolled_val_key, {:scroll, :down, s_area.x + 2, s_area.y + 2})

      assert scrolled_sum.inspector_summary_scroll == 3
      assert scrolled_sum.inspector_value_scroll == 5

      scrolled_sum_key = App.handle_key(scrolled_sum, "}")
      assert scrolled_sum_key.inspector_summary_scroll == 5

      # Format toggle 'm' cycles :auto -> :text -> :raw -> :auto
      fmt1 = App.handle_key(scrolled_sum_key, "m")
      assert fmt1.inspector_format == :text
      assert fmt1.inspector_value_scroll == 0

      # Moving selection in grid resets inspector scroll offsets cleanly
      moved_down = App.handle_key(scrolled_sum_key, :down)
      assert moved_down.datagrid_state.selected_cell == {1, 0}
      assert moved_down.inspector_value_scroll == 0
      assert moved_down.inspector_summary_scroll == 0

      # Clicking a column row inside Summary selects that column in the grid
      clicked_col = App.handle_mouse(app, {:click, s_area.x + 2, s_area.y + 3})
      assert clicked_col.datagrid_state.selected_cell == {0, 2}
    end

    test "preserves filter during header sort, supports clickable [Run]/[×] pills, filter history, and live debounce" do
      prof = %Strata.ConnectionProfile{
        id: "filter_sort_sqlite_#{System.unique_integer([:positive])}",
        name: "FilterSort SQLite",
        driver: :sqlite,
        database: ":memory:"
      }

      :ok = Strata.ConfigStore.put_profile(prof)

      on_exit(fn ->
        Strata.ConnectionSupervisor.stop_worker(prof.id)
        Strata.ConfigStore.delete_profile(prof.id)
        Strata.DataStore.invalidate_connection_cache(prof.id)
      end)

      assert {:ok, _} =
               Strata.ConnectionWorker.execute_query_for_profile(
                 prof,
                 "CREATE TABLE products (id INTEGER PRIMARY KEY, category TEXT, name TEXT)"
               )

      assert {:ok, _} =
               Strata.ConnectionWorker.execute_query_for_profile(
                 prof,
                 "INSERT INTO products VALUES (1, 'book', 'Zebra'), (2, 'book', 'Alpha'), (3, 'music', 'Jazz')"
               )

      nodes = [
        %{
          id: prof.id,
          label: "FilterSort SQLite",
          type: :connection,
          expanded?: true,
          children: [
            %{
              id: "#{prof.id}_schema_main",
              label: "main",
              type: :schema,
              expanded?: true,
              children: [
                %{
                  id: "#{prof.id}_main_tbl_products",
                  label: "products",
                  type: :table,
                  schema: "main",
                  children: []
                }
              ]
            }
          ]
        }
      ]

      grid =
        Strata.UI.Components.DataGrid.new(
          ["id", "category", "name"],
          [[1, "book", "Zebra"], [2, "book", "Alpha"], [3, "music", "Jazz"]],
          mode: :selecting,
          selected_cell: {0, 1}
        )

      app =
        App.new(
          focus: :datagrid,
          active_view: :table_view,
          selected_table: "products",
          selected_schema: "main",
          sidebar_nodes: nodes,
          selected_tree_node_id: "#{prof.id}_main_tbl_products",
          datagrid_state: grid,
          window_size: {120, 40}
        )

      # 1. Apply Shift+F filter on category='book', then sort by name header -> filter is preserved!
      filtered = App.handle_key(app, "F")
      tab_id = filtered.active_tab_id

      assert_receive {:filter_query_finished, ^tab_id, "category = book", "", {:ok, res1}}, 2_000

      {:noreply, filtered_loaded} =
        App.handle_info(
          {:filter_query_finished, tab_id, "category = book", "", {:ok, res1}},
          filtered
        )

      assert length(filtered_loaded.datagrid_state.rows) == 2

      # Sort while selected on column 2 preserves selected column, col_offset, and mode
      filtered_on_col2 = %{
        filtered_loaded
        | datagrid_state: %{
            filtered_loaded.datagrid_state
            | selected_cell: {0, 2},
              col_offset: 1,
              mode: :selecting
          }
      }

      sorted = App.sort_active_table_by_col(filtered_on_col2, 2)
      assert_receive {:table_sorted_loaded, s_req_id, "products", {"name", :asc}, s_res}, 2_000

      {:noreply, sorted_loaded} =
        App.handle_info(
          {:table_sorted_loaded, s_req_id, "products", {"name", :asc}, s_res},
          sorted
        )

      assert sorted_loaded.datagrid_state.sort_by == {"name", :asc}
      assert sorted_loaded.datagrid_state.selected_cell == {0, 2}
      assert sorted_loaded.datagrid_state.col_offset == 1
      assert sorted_loaded.datagrid_state.mode == :selecting
      assert Enum.map(sorted_loaded.datagrid_state.rows, &Enum.at(&1, 2)) == ["Alpha", "Zebra"]

      # Clicking [Op ▾] pill opens operator dropdown and clicking an item picks it cleanly
      layout0 = Strata.UI.Renderer.layout({120, 40}, :table_view)
      bar_for_dd = App.handle_key(sorted_loaded, "/")
      areas0 = Strata.UI.Renderer.datagrid_areas(layout0.datagrid, bar_for_dd)
      rects0 = Strata.UI.Renderer.filter_bar_rects(areas0.filter_area, bar_for_dd)
      op_dd_app = App.handle_mouse(bar_for_dd, {:click, rects0.op_rect.x, rects0.op_rect.y})
      assert op_dd_app.filter_dropdown == :op

      # Mouse scroll while dropdown is open scrolls dropdown items and locks background grid scroll
      scrolled_dd =
        op_dd_app
        |> Map.put(:datagrid_state, %{
          op_dd_app.datagrid_state
          | rows: Enum.map(1..50, &[&1, "book", "Item #{&1}"]),
            total_rows: 50,
            scroll_offset: 0
        })
        |> App.handle_mouse({:scroll, :down, rects0.op_rect.x, rects0.op_rect.y + 4})

      assert scrolled_dd.filter_dropdown_idx == 1
      assert scrolled_dd.datagrid_state.scroll_offset == 0

      dd_data = Strata.UI.Renderer.filter_dropdown_data(op_dd_app, layout0.datagrid)
      # Click 3rd operator ("=") in dropdown
      clicked_eq = App.handle_mouse(op_dd_app, {:click, dd_data.rect.x + 1, dd_data.rect.y + 3})
      assert clicked_eq.filter_bar_op == :=
      assert clicked_eq.filter_dropdown == nil
      assert clicked_eq.filter_bar_focus_part == :value

      # 2. Filter History via Up arrow recalls prior filters, Down steps forward back to empty
      reopened = App.handle_key(sorted_loaded, "/")
      assert reopened.filter_bar_text == ""
      recalled = App.handle_key(reopened, :up)
      assert recalled.filter_bar_text == "book"
      assert recalled.filter_bar_col == "category"

      cleared_hist = App.handle_key(recalled, :down)
      assert cleared_hist.filter_bar_text == ""

      # 3. Typing does NOT auto-run; query only executes when clicking [Run] or pressing Enter
      typed = App.handle_key(cleared_hist, "j")
      assert typed.filter_bar_text == "j"
      refute_receive {:filter_query_finished, ^tab_id, "* All contains j", "", _}, 100

      # 4. Clickable [Run] and [×] pills work cleanly via mouse coordinates
      layout = Strata.UI.Renderer.layout({120, 40}, :table_view)
      areas = Strata.UI.Renderer.datagrid_areas(layout.datagrid, typed)
      rects = Strata.UI.Renderer.filter_bar_rects(areas.filter_area, typed)

      clicked_run = App.handle_mouse(typed, {:click, rects.run_rect.x, rects.run_rect.y})
      assert clicked_run.filter_bar_focused == false

      assert_receive {:filter_query_finished, ^tab_id, "* All contains j", "", {:ok, res_j}},
                     2_000

      assert length(res_j.rows) == 1
      assert hd(res_j.rows) == [3, "music", "Jazz"]

      clicked_clear =
        App.handle_mouse(clicked_run, {:click, rects.clear_rect.x, rects.clear_rect.y})

      assert clicked_clear.active_filter == nil
      assert clicked_clear.filter_bar_open == false
      assert_receive {:table_data_loaded, t_req_id, pid, schema, "products", t_res}, 2_000

      {:noreply, reloaded_clear} =
        App.handle_info(
          {:table_data_loaded, t_req_id, pid, schema, "products", t_res},
          clicked_clear
        )

      # 5. In Browsing mode, pressing 'o' opens Unified Filter & Sort Bar directly on Sort dropdown
      browsing_app = %{
        reloaded_clear
        | datagrid_state: %{reloaded_clear.datagrid_state | mode: :browsing}
      }

      sp_app = App.handle_key(browsing_app, "o")
      assert sp_app.filter_bar_open == true
      assert sp_app.filter_dropdown == :sort
      assert Strata.UI.KeyRegistry.determine_context(sp_app) == :filter_bar

      # Mouse wheel scroll locks inside sort dropdown without scrolling background grid
      sp_scrolled = App.handle_mouse(sp_app, {:scroll, :down, 50, 10})
      assert sp_scrolled.filter_dropdown_idx == 1

      # Pressing Esc while transient sort dropdown is open closes both dropdown and bar
      esc_sort = App.handle_key(sp_app, :esc)
      assert esc_sort.filter_dropdown == nil
      assert esc_sort.filter_bar_open == false

      # Typing narrows columns and Enter sorts the picked column cleanly & collapses transient bar
      sp_typed = App.handle_key(sp_app, "c")
      picked_sort = App.handle_key(sp_typed, :enter)
      assert picked_sort.filter_dropdown == nil
      assert picked_sort.filter_bar_open == false
      assert picked_sort.datagrid_state.sort_by == {"category", :asc}

      assert_receive {:table_sorted_loaded, s2_req_id, "products", {"category", :asc}, s2_res},
                     2_000

      {:noreply, sorted_cat} =
        App.handle_info(
          {:table_sorted_loaded, s2_req_id, "products", {"category", :asc}, s2_res},
          picked_sort
        )

      # 6. Unified bar Tab cycling + Ctrl+G opens current table/filter/sort in SQL Editor tab
      unified = App.handle_key(sorted_cat, "f")
      assert unified.filter_bar_focus_part == :value
      assert App.handle_key(unified, :tab).filter_bar_focus_part == :sort

      assert unified
             |> App.handle_key(:tab)
             |> App.handle_key(:tab)
             |> Map.get(:filter_bar_focus_part) == :column

      {:noreply, typed_for_sql} =
        App.handle_event(%ExRatatui.Event.Paste{content: "book"}, unified)

      sql_tab_app = App.handle_key(typed_for_sql, {:ctrl, "g"})
      assert sql_tab_app.active_view == :query_view
      assert sql_tab_app.focus == :editor
      active_sql_tab = Enum.find(sql_tab_app.tabs, &(&1.id == sql_tab_app.active_tab_id))
      assert active_sql_tab.content =~ "SELECT *"
      assert active_sql_tab.content =~ "\"products\""
      assert active_sql_tab.content =~ "LIKE '%book%'"
      assert active_sql_tab.content =~ "ORDER BY \"category\" ASC"
    end

    test "restarts worker on ConnectionModal edit, confirms before delete, filters sidebar with /, and renders active DB on SQL Editor" do
      prof = %Strata.ConnectionProfile{
        id: "ux_conn_#{System.unique_integer([:positive])}",
        name: "Analytics SQLite",
        driver: :sqlite,
        database: ":memory:"
      }

      :ok = Strata.ConfigStore.put_profile(prof)

      on_exit(fn ->
        Strata.ConnectionSupervisor.stop_worker(prof.id)
        Strata.ConfigStore.delete_profile(prof.id)
      end)

      # Start persistent worker & seed cache
      assert {:ok, worker1} = Strata.ConnectionSupervisor.get_or_start_worker(prof)
      Strata.DataStore.put_table_cache(prof.id, "main", "events", ["id"], [[1]], false)

      app =
        App.new(
          focus: :sidebar,
          sidebar_nodes: [
            %{
              id: prof.id,
              label: "Analytics SQLite (SQLITE)",
              type: :connection,
              expanded?: true,
              children: [
                %{
                  id: "#{prof.id}_schema_main",
                  label: "main",
                  type: :schema,
                  expanded?: true,
                  children: [
                    %{
                      id: "#{prof.id}_main_tbl_events",
                      label: "events",
                      type: :table,
                      schema: "main",
                      children: []
                    },
                    %{
                      id: "#{prof.id}_main_tbl_users",
                      label: "users",
                      type: :table,
                      schema: "main",
                      children: []
                    }
                  ]
                }
              ]
            }
          ],
          selected_tree_node_id: prof.id
        )

      # 1. Saving edited ConnectionModal stops stale worker & invalidates cache
      modal = Strata.UI.Components.ConnectionModal.new(profile: prof)
      editing_app = App.push_modal(app, %{modal | name: "Analytics Renamed"})
      saved_app = App.handle_key(editing_app, {:ctrl, "s"})
      assert saved_app.modals == []
      assert {:error, :not_found} = Strata.ConnectionSupervisor.lookup_worker(prof.id)
      refute Process.alive?(worker1)
      assert :miss = Strata.DataStore.get_table_cache(prof.id, "main", "events")

      # 2. Pressing 'd' opens confirmation modal instead of deleting immediately
      confirm_app = App.handle_key(app, "d")
      assert [%{type: :confirm_delete_connection, profile_id: pid_to_del}] = confirm_app.modals
      assert pid_to_del == prof.id
      assert Strata.ConfigStore.get_profile(prof.id) != nil

      # Pressing 'n' cancels deletion safely
      cancelled_app = App.handle_key(confirm_app, "n")
      assert cancelled_app.modals == []
      assert Strata.ConfigStore.get_profile(prof.id) != nil

      # 3. Sidebar search '/' filters visible tree and loads matching table on Enter
      {:noreply, filter_mode} =
        App.handle_event(%ExRatatui.Event.Key{code: "/", kind: "press"}, app)

      assert filter_mode.sidebar_filter_active == true

      {:noreply, typed_filter} =
        App.handle_event(%ExRatatui.Event.Key{code: "u", kind: "press"}, filter_mode)

      {:noreply, typed_filter} =
        App.handle_event(%ExRatatui.Event.Key{code: "s", kind: "press"}, typed_filter)

      visible = Strata.UI.Components.Sidebar.visible_nodes(typed_filter)
      assert Enum.any?(visible, &(&1.label == "users"))
      refute Enum.any?(visible, &(&1.label == "events"))

      # 4. Renderer shows active connection & schema on SQL Editor block title
      query_app = %{
        app
        | active_view: :query_view,
          selected_tree_node_id: "#{prof.id}_main_tbl_users"
      }

      widgets = Strata.UI.Renderer.render(query_app)

      assert Enum.any?(widgets, fn
               {%ExRatatui.Widgets.Paragraph{block: %ExRatatui.Widgets.Block{title: title}},
                _rect} ->
                 String.contains?(title, "SQL EDITOR [Analytics Renamed · main]")

               _ ->
                 false
             end)

      # Confirming delete with 'y' deletes profile
      confirmed_del = App.handle_key(confirm_app, "y")
      assert confirmed_del.modals == []
      assert Strata.ConfigStore.get_profile(prof.id) == nil
    end

    test "scroll handle_event skips redraw (render?: false) on boundary no-op and scroll-lock-damped events" do
      cols = ["id", "c1", "c2", "c3", "c4", "c5", "c6"]

      rows =
        for i <- 1..60,
            do: [
              i,
              "val_#{i}_a",
              "val_#{i}_b",
              "val_#{i}_c",
              "val_#{i}_d",
              "val_#{i}_e",
              "val_#{i}_f"
            ]

      grid =
        Strata.UI.Components.DataGrid.new(cols, rows,
          mode: :browsing,
          scroll_offset: 0,
          col_offset: 0
        )

      app =
        App.new(
          window_size: {80, 24},
          active_view: :table_view,
          focus: :datagrid,
          datagrid_state: grid
        )

      g_area =
        Strata.UI.Renderer.datagrid_areas(
          Strata.UI.Renderer.layout({80, 24}, :table_view).datagrid,
          app
        ).grid_area

      gx = g_area.x + 2
      gy = g_area.y + 3

      # Scrolling up at top boundary (scroll_offset == 0) is a visual no-op -> render?: false
      {:noreply, top_noop, opts_top} =
        App.handle_event(%ExRatatui.Event.Mouse{kind: "scroll_up", x: gx, y: gy}, app)

      assert top_noop.datagrid_state.scroll_offset == 0
      assert Keyword.get(opts_top, :render?) == false

      # Scrolling down moves scroll_offset -> render?: true
      {:noreply, scrolled_down, opts_down} =
        App.handle_event(%ExRatatui.Event.Mouse{kind: "scroll_down", x: gx, y: gy}, top_noop)

      assert scrolled_down.datagrid_state.scroll_offset > 0
      assert Keyword.get(opts_down, :render?) == true

      # Horizontal scroll immediately after vertical burst is blocked by vertical scroll_lock -> render?: false
      {:noreply, damped_h, opts_h} =
        App.handle_event(
          %ExRatatui.Event.Mouse{kind: "scroll_right", x: gx, y: gy},
          scrolled_down
        )

      assert damped_h.datagrid_state.col_offset == 0
      assert Keyword.get(opts_h, :render?) == false
    end

    test "hotkey fixes: sidebar filter 'q' does not quit, '-' clears sort, 'e'/'E'/'d' unified, Ctrl+P & Ctrl+K work" do
      # 1. Typing 'q' inside sidebar filter types 'q' instead of quitting app
      filtering_app = App.new(focus: :sidebar, sidebar_filter_active: true, sidebar_filter: "")

      assert {:noreply, typed_app} =
               App.handle_event(%ExRatatui.Event.Key{code: "q", modifiers: []}, filtering_app)

      assert typed_app.sidebar_filter == "q"

      # 2. F4 event toggles Right Inspector Drawer via map_ex_ratatui_key
      grid_app =
        App.new(
          focus: :datagrid,
          active_view: :table_view,
          datagrid_state:
            Strata.UI.Components.DataGrid.new(["id", "name"], [[1, "Alpha"]],
              sort_by: {"name", :asc}
            )
        )

      {:noreply, f4_app} =
        App.handle_event(%ExRatatui.Event.Key{code: "f4", modifiers: []}, grid_app)

      assert f4_app.inspector_open == true

      # 3. '-' clears active sort in both :browsing and :selecting modes
      cleared_browsing = App.handle_key(grid_app, "-")
      assert cleared_browsing.datagrid_state.sort_by == nil

      selecting_sorted = %{
        grid_app
        | datagrid_state: %{grid_app.datagrid_state | mode: :selecting}
      }

      cleared_selecting = App.handle_key(selecting_sorted, "-")
      assert cleared_selecting.datagrid_state.sort_by == nil

      # 4. In :browsing mode, 'e' edits cell, 'E' opens ExportModal, and 'd' marks row for delete
      editing_from_browsing = App.handle_key(grid_app, "e")
      assert editing_from_browsing.datagrid_state.editing_cell == {0, 0}

      export_from_browsing = App.handle_key(grid_app, "E")
      assert match?([%Strata.UI.Components.ExportModal{}], export_from_browsing.modals)

      deleted_from_browsing = App.handle_key(grid_app, "d")
      assert MapSet.member?(deleted_from_browsing.datagrid_state.pending_deletes, 0)

      # 5. Ctrl+P opens context-aware ActionsModal from :editor and Ctrl+K clears SQL editor
      editor_app =
        App.new(focus: :editor)
        |> put_in([Access.key(:tabs), Access.at(0), :content], "SELECT * FROM users")
        |> put_in([Access.key(:tabs), Access.at(0), :cursor], {0, 19})

      actions_from_editor = App.handle_key(editor_app, {:ctrl, "p"})

      assert [%Strata.UI.Components.ActionsModal{items: items}] = actions_from_editor.modals
      assert hd(items).id == :run_query

      cleared_editor = App.handle_key(editor_app, {:ctrl, "k"})
      active_tab = Enum.find(cleared_editor.tabs, &(&1.id == cleared_editor.active_tab_id))
      assert active_tab.content == ""
      assert active_tab.cursor == {0, 0}
    end

    test "clicks horizontal modal buttons accurately across ConnectionModal and ExportModal" do
      cm = Strata.UI.Components.ConnectionModal.new(name: "Click DB")
      app = App.new(window_size: {120, 40}) |> App.push_modal(cm)
      area = Strata.UI.Renderer.modal_area_for(app, {120, 40})
      fields = Strata.UI.Components.ConnectionModal.render(cm, area).fields
      {inputs, buttons} = Enum.split_with(fields, &(&1.type != :button))
      layout = Strata.UI.Renderer.modal_button_bar_layout(buttons, area.width - 2)
      btn_y = area.y + 1 + length(inputs) + 1

      cancel_btn = Enum.find(layout.all, &(&1.key == :cancel_button))
      cancel_x = area.x + 1 + cancel_btn.start_x + 2
      after_cancel = App.handle_mouse(app, {:click, cancel_x, btn_y})
      assert after_cancel.modals == []

      test_btn = Enum.find(layout.all, &(&1.key == :test_button))
      test_x = area.x + 1 + test_btn.start_x + 2
      after_test = App.handle_mouse(app, {:click, test_x, btn_y})
      assert hd(after_test.modals).status == :testing
      assert hd(after_test.modals).focused_field == :test_button
    end

    test "preserves tree expansion cleanly on :connection_schema_loaded with flattened table nodes (no :expanded? key)" do
      table_node = %{
        id: "conn1_public_tbl_users",
        label: "users",
        type: :table,
        profile_id: "conn1",
        schema: "public"
      }

      conn_node = %{
        id: "conn1",
        label: "Prod DB (PG)",
        type: :connection,
        expanded?: true,
        children: [table_node]
      }

      app = App.new(sidebar_nodes: [conn_node])

      {:noreply, updated_app} =
        App.handle_info({:connection_schema_loaded, "conn1", conn_node}, app)

      assert [%{id: "conn1", expanded?: true, children: [%{id: "conn1_public_tbl_users"}]}] =
               updated_app.sidebar_nodes
    end

    test "prompts ConfirmModal before closing dirty table tab or quitting and handles discard/cancel/commit" do
      alias Strata.UI.Components.{ConfirmModal, DataGrid}

      dirty_grid =
        DataGrid.new(["id", "name"], [[1, "Alice"]], primary_keys: ["id"])
        |> DataGrid.stage_cell_edit(0, 1, "Alicia")

      table_tab = %{
        id: "tab_tbl_dirty",
        kind: :table,
        name: "users",
        table_name: "users",
        schema: "main",
        profile_id: nil,
        datagrid_state: dirty_grid
      }

      app =
        App.new(
          tabs: [table_tab],
          active_tab_id: "tab_tbl_dirty",
          active_view: :table_view,
          selected_table: "users",
          datagrid_state: dirty_grid,
          focus: :datagrid
        )

      # 1. Ctrl+W on dirty tab pushes ConfirmModal instead of discarding edits
      prompted = App.handle_key(app, {:ctrl, "w"})

      assert [%ConfirmModal{kind: :close_dirty_tab, tab_id: "tab_tbl_dirty", dirty_count: 1}] =
               prompted.modals

      assert length(prompted.tabs) == 1

      # 2. Esc cancels and keeps tab + staged edits intact
      cancelled = App.handle_key(prompted, :esc)
      assert cancelled.modals == []
      assert length(cancelled.tabs) == 1
      assert DataGrid.dirty_count(cancelled.datagrid_state) == 1

      # 3. Inline editing also triggers ConfirmModal when closing via close_tab
      inline_app = %{
        app
        | datagrid_state: %{DataGrid.new(["id", "name"], [[1, "Alice"]]) | editing_cell: {0, 1}}
      }

      inline_prompted = App.close_tab(inline_app, "tab_tbl_dirty")

      assert [%ConfirmModal{kind: :close_dirty_tab, inline_editing?: true}] =
               inline_prompted.modals

      # 4. Choosing Discard & Close closes the tab
      discard_focused =
        App.handle_key(
          %{prompted | modals: [%{hd(prompted.modals) | focused_field: :discard_button}]},
          :enter
        )

      assert discard_focused.modals == []
      assert discard_focused.tabs == []

      # 5. Pressing 'q' when dirty tab exists opens ConfirmModal; Discard & Quit stops app
      {:noreply, quit_prompted} =
        App.handle_event(%ExRatatui.Event.Key{code: "q", modifiers: []}, app)

      assert [%ConfirmModal{kind: :quit_with_dirty_tabs, can_commit?: true}] =
               quit_prompted.modals

      discard_quit_app = %{
        quit_prompted
        | modals: [%{hd(quit_prompted.modals) | focused_field: :discard_button}]
      }

      assert {:stop, stopped} =
               App.handle_event(
                 %ExRatatui.Event.Key{code: "enter", modifiers: []},
                 discard_quit_app
               )

      assert stopped.quit_requested? == true

      # 6. Commit finishing for :close_dirty_tab closes the tab cleanly; error keeps modal & edits
      err_state = %{
        prompted
        | pending_commit_action: {:close_tab, "tab_tbl_dirty"},
          modals: [
            %{hd(prompted.modals) | status: :saving, status_message: "⏳ Committing changes..."}
          ]
      }

      {:noreply, rolled_back} =
        App.handle_info(
          {:commit_finished, 1, "p1", "main", "users", {:error, "Constraint failed"}},
          err_state
        )

      assert [%ConfirmModal{status: :error, status_message: msg}] = rolled_back.modals
      assert msg =~ "Constraint failed"
      assert length(rolled_back.tabs) == 1

      ok_state = %{
        prompted
        | pending_commit_action: {:close_tab, "tab_tbl_dirty"},
          modals: [
            %{hd(prompted.modals) | status: :saving, status_message: "⏳ Committing changes..."}
          ]
      }

      {:noreply, committed_closed} =
        App.handle_info({:commit_finished, 2, "p1", "main", "users", {:ok, 1}}, ok_state)

      assert committed_closed.modals == []
      assert committed_closed.tabs == []
      assert committed_closed.status_message =~ "Committed 1 statement(s) and closed 'users'"
    end

    test "protects dirty table on refresh/filter/clear-sort" do
      alias Strata.UI.Components.{ConfirmModal, DataGrid}

      dirty_grid =
        DataGrid.new(["id", "name"], [[1, "Alice"]],
          primary_keys: ["id"],
          sort_by: {"name", :asc}
        )
        |> DataGrid.stage_cell_edit(0, 1, "Alicia")

      table_tab = %{
        id: "tab_tbl_guard",
        kind: :table,
        name: "users",
        table_name: "users",
        schema: "main",
        profile_id: nil,
        datagrid_state: dirty_grid
      }

      app =
        App.new(
          tabs: [table_tab],
          active_tab_id: "tab_tbl_guard",
          active_view: :table_view,
          selected_table: "users",
          datagrid_state: dirty_grid,
          active_filter: %{
            mode: :builder,
            column: "name",
            op: :contains,
            value: "Al",
            summary: "name contains Al"
          },
          focus: :datagrid
        )

      # 1. Refresh on dirty table opens ConfirmModal instead of discarding
      refreshed = App.refresh_active_table(app)
      assert [%ConfirmModal{kind: :refresh_dirty_table, tab_name: "users"}] = refreshed.modals
      assert DataGrid.dirty_count(refreshed.datagrid_state) == 1

      # 2. Filter apply, filter clear, and clear_active_sort preserve edits and warn
      filtered =
        App.handle_key(
          %{app | filter_bar_open: true, filter_bar_focused: true, filter_bar_text: "Al"},
          :enter
        )

      assert filtered.status_message =~ "before filtering"
      assert DataGrid.dirty_count(filtered.datagrid_state) == 1

      cleared_filter = App.clear_table_filter(app)
      assert cleared_filter.status_message =~ "before clearing filter"
      assert cleared_filter.active_filter != nil
      assert DataGrid.dirty_count(cleared_filter.datagrid_state) == 1

      cleared_sort = App.clear_active_sort(app)
      assert cleared_sort.status_message =~ "before clearing sort"
      assert DataGrid.dirty_count(cleared_sort.datagrid_state) == 1
    end

    test "supports opening, filtering, selecting via keyboard/mouse, and Esc-closing floating modal dropdowns" do
      # 1. ConnectionModal :driver — Enter opens dropdown, typing filters, Enter picks sqlite
      cm = Strata.UI.Components.ConnectionModal.new(focused_field: :driver)
      app = App.new(window_size: {120, 40}) |> App.push_modal(cm)

      opened = App.handle_key(app, :enter)
      assert opened.modal_dropdown == %{field: :driver, index: 0, search: ""}

      # Esc closes only the dropdown, keeping the modal open
      dismissed = App.handle_key(opened, :esc)
      assert dismissed.modal_dropdown == nil
      assert [%Strata.UI.Components.ConnectionModal{}] = dismissed.modals

      # Reopen, type "sq" to filter to sqlite, then Enter selects sqlite
      chosen =
        dismissed
        |> App.handle_key(:enter)
        |> App.handle_key("s")
        |> App.handle_key("q")
        |> App.handle_key(:enter)

      assert chosen.modal_dropdown == nil
      assert [%Strata.UI.Components.ConnectionModal{driver: :sqlite}] = chosen.modals

      # Left/Right quick-cycling continues to work directly when dropdown is closed
      cycled = App.handle_key(chosen, :right)
      assert cycled.modal_dropdown == nil
      assert [%Strata.UI.Components.ConnectionModal{driver: :postgres}] = cycled.modals

      # 2. Mouse click on ExportModal :format row opens dropdown, clicking option applies it
      export_app =
        App.new(window_size: {120, 40})
        |> App.push_modal(Strata.UI.Components.ExportModal.new())

      area = Strata.UI.Renderer.modal_area_for(export_app, {120, 40})
      clicked_open = App.handle_mouse(export_app, {:click, area.x + 5, area.y + 1})
      assert %{field: :format} = clicked_open.modal_dropdown

      dd_data = Strata.UI.Renderer.modal_dropdown_data(clicked_open, {120, 40})
      # Row 1 inside dropdown is "json (.json)"
      clicked_json =
        App.handle_mouse(clicked_open, {:click, dd_data.rect.x + 3, dd_data.rect.y + 2})

      assert clicked_json.modal_dropdown == nil

      assert [%Strata.UI.Components.ExportModal{format: :json, file_path: "export.json"}] =
               clicked_json.modals

      # 3. AISettingsModal :context_scope dropdown keyboard selection
      ai_app =
        App.new(window_size: {120, 40})
        |> App.push_modal(Strata.UI.Components.AISettingsModal.new(focused_field: :context_scope))
        |> App.handle_key(:enter)
        |> App.handle_key(:down)
        |> App.handle_key(:enter)

      assert [%Strata.UI.Components.AISettingsModal{context_scope: :focused_only}] = ai_app.modals
    end

    test "bootstrap connects only auto_connect profiles, supports on-demand connect, disconnect, and profile reconciliation" do
      manual_prof = %Strata.ConnectionProfile{
        id: "lazy_manual_#{System.unique_integer([:positive])}",
        name: "Manual SQLite",
        driver: :sqlite,
        database: ":memory:",
        auto_connect: false
      }

      auto_prof = %Strata.ConnectionProfile{
        id: "lazy_auto_#{System.unique_integer([:positive])}",
        name: "Auto SQLite",
        driver: :sqlite,
        database: ":memory:",
        auto_connect: true
      }

      :ok = Strata.ConfigStore.put_profile(manual_prof)
      :ok = Strata.ConfigStore.put_profile(auto_prof)

      on_exit(fn ->
        Strata.ConnectionSupervisor.stop_worker(manual_prof.id)
        Strata.ConnectionSupervisor.stop_worker(auto_prof.id)
        Strata.ConfigStore.delete_profile(manual_prof.id)
        Strata.ConfigStore.delete_profile(auto_prof.id)
      end)

      # 1. App.new builds idle nodes without starting workers
      app = App.new(focus: :sidebar)
      manual_node = Enum.find(app.sidebar_nodes, &(&1.id == manual_prof.id))
      assert [%{id: manual_idle_id}] = manual_node.children
      assert manual_idle_id == "#{manual_prof.id}_idle"
      assert {:error, :not_found} = Strata.ConnectionSupervisor.lookup_worker(manual_prof.id)
      assert {:error, :not_found} = Strata.ConnectionSupervisor.lookup_worker(auto_prof.id)

      # 2. :bootstrap only connects auto_connect: true profiles
      bootstrapped =
        case App.handle_info(:bootstrap, app) do
          {:noreply, s} -> s
          {:noreply, s, _opts} -> s
        end

      auto_id = auto_prof.id
      manual_id = manual_prof.id
      assert_receive {:connection_schema_loaded, ^auto_id, _loaded_node}, 2_000
      refute_receive {:connection_schema_loaded, ^manual_id, _}, 100

      assert {:error, :not_found} = Strata.ConnectionSupervisor.lookup_worker(manual_prof.id)
      assert bootstrapped.connection_statuses[manual_prof.id] == nil
      assert bootstrapped.connection_statuses[auto_prof.id] == :connecting

      # 3. Pressing Enter on idle connection triggers on-demand connection
      idle_app = %{bootstrapped | selected_tree_node_id: manual_prof.id}

      {:noreply, connecting_app} =
        App.handle_event(%ExRatatui.Event.Key{code: "enter", kind: "press"}, idle_app)

      assert connecting_app.connection_statuses[manual_prof.id] == :connecting
      assert connecting_app.status_message =~ "Connecting"

      assert_receive {:connection_schema_loaded, m_id, loaded_manual_node}, 2_000
      assert m_id == manual_prof.id

      {:noreply, connected_app} =
        App.handle_info({:connection_schema_loaded, m_id, loaded_manual_node}, connecting_app)

      assert {:ok, _worker} = Strata.ConnectionSupervisor.lookup_worker(manual_prof.id)
      assert connected_app.connection_statuses[manual_prof.id] == :connected
      assert connected_app.status_message =~ "Connected"

      # Offline fallback node clears connecting status and marks :disconnected
      offline_node = Strata.SchemaInspector.fetch_fallback_nodes(manual_prof, :econnrefused)

      {:noreply, offline_app} =
        App.handle_info({:connection_schema_loaded, m_id, offline_node}, connecting_app)

      assert offline_app.connection_statuses[manual_prof.id] == :disconnected
      assert offline_app.status_message =~ "Offline"

      # 4. {:profiles_updated, ...} preserves loaded manual_node and adds new profile as idle
      extra_prof = %Strata.ConnectionProfile{
        id: "lazy_extra_#{System.unique_integer([:positive])}",
        name: "Extra PG",
        driver: :postgres,
        host: "127.0.0.1",
        port: 5432,
        auto_connect: false
      }

      {:noreply, reconciled_app} =
        App.handle_info({:profiles_updated, [manual_prof, auto_prof, extra_prof]}, connected_app)

      preserved_manual = Enum.find(reconciled_app.sidebar_nodes, &(&1.id == manual_prof.id))
      refute match?([%{id: ^manual_idle_id}], preserved_manual.children)
      extra_node = Enum.find(reconciled_app.sidebar_nodes, &(&1.id == extra_prof.id))
      assert [%{id: extra_idle_id}] = extra_node.children
      assert extra_idle_id == "#{extra_prof.id}_idle"

      # 5. Pressing 'u' disconnects selected connection and resets it back to idle
      disconnected_app =
        App.handle_key(%{reconciled_app | selected_tree_node_id: manual_prof.id}, "u")

      assert {:error, :not_found} = Strata.ConnectionSupervisor.lookup_worker(manual_prof.id)
      assert disconnected_app.connection_statuses[manual_prof.id] == nil
      assert disconnected_app.status_message =~ "Disconnected"
      reset_manual = Enum.find(disconnected_app.sidebar_nodes, &(&1.id == manual_prof.id))
      assert [%{id: reset_idle_id}] = reset_manual.children
      assert reset_idle_id == "#{manual_prof.id}_idle"
    end
  end
end
