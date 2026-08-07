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

      modal1 = %{type: :connection_modal, title: "New Connection"}
      app = App.push_modal(app, modal1)
      assert app.modals == [modal1]

      modal2 = %{type: :ssh_modal, title: "SSH Profile"}
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

      app = App.handle_key(app, "1")
      assert app.active_view == :table_view

      app = App.handle_key(app, "2")
      assert app.active_view == :query_view

      app = App.handle_key(app, {:ctrl, "1"})
      assert app.active_view == :table_view

      app = App.handle_key(app, {:ctrl, "2"})
      assert app.active_view == :query_view
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

      # Window size 120x40, table_view active (datagrid full height, x: 30, y: 0)
      app = App.new(active_view: :table_view, datagrid_state: grid, window_size: {120, 40})

      # Column widths:
      # Col 0 ("id"): 5  -> rel_x: 0..4 (x: 31..35)
      # Col 1 ("name"): 8 -> rel_x: 6..13 (x: 37..44)
      # Col 2 ("role"): 12 -> rel_x: 15..26 (x: 46..57)
      # Col 3 ("status"): 11 -> rel_x: 28..38 (x: 59..69)
      # Col 4 ("email"): 20 -> rel_x: 40..59 (x: 71..90)

      # Click Col 0 ("id"): x = 33, y = 2
      a0 = App.handle_mouse(app, {:click, 33, 2})
      assert a0.datagrid_state.selected_cell == {0, 0}

      # Click Col 1 ("name"): x = 38, y = 2
      a1 = App.handle_mouse(app, {:click, 38, 2})
      assert a1.datagrid_state.selected_cell == {0, 1}

      # Click Col 2 ("role"): x = 45, y = 2
      a2 = App.handle_mouse(app, {:click, 45, 2})
      assert a2.datagrid_state.selected_cell == {0, 2}

      # Click Col 3 ("status"): x = 55, y = 3
      a3 = App.handle_mouse(app, {:click, 55, 3})
      assert a3.datagrid_state.selected_cell == {1, 3}

      # Click Col 4 ("email"): x = 65, y = 3
      a4 = App.handle_mouse(app, {:click, 65, 3})
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

    test "Esc in editor focus mode unfocuses back to datagrid (navigation mode)" do
      app = App.new(focus: :editor)
      app = App.handle_key(app, :esc)
      assert app.focus == :datagrid
    end
  end

  describe "Table view load_more_table_data & infinite scroll" do
    test "load_more_table_data triggers async Task and updates state via handle_info" do
      grid = Strata.UI.Components.DataGrid.new(["id", "name"], [[1, "User 1"]], has_more: true, loading_more: false)

      app =
        App.new(
          active_view: :table_view,
          selected_table: "users",
          datagrid_state: grid
        )

      updated = App.load_more_table_data(app)

      assert updated.datagrid_state.loading_more == true
      assert updated.status_message =~ "Loading more rows"

      # Simulate receiving async chunk loaded message
      fake_result = {:ok, ["id", "name"], [[2, "User 2"]]}
      {:noreply, final_state} = App.handle_info({:table_chunk_loaded, "users", 1, fake_result}, updated)

      assert final_state.datagrid_state.loading_more == false
      assert length(final_state.datagrid_state.rows) == 2
      assert final_state.status_message =~ "Loaded +1 rows"
    end

    test "load_more_table_data ignores request if has_more is false or loading_more is true" do
      grid = Strata.UI.Components.DataGrid.new(["id", "name"], [[1, "User 1"]], has_more: false, loading_more: false)

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
end
