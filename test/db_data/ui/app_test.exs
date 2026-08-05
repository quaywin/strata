defmodule DBData.UI.AppTest do
  use ExUnit.Case, async: true

  alias DBData.UI.App

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
      app = App.new(focus: :sidebar)

      app = App.cycle_focus(app, :next)
      assert app.focus == :editor

      app = App.cycle_focus(app, :next)
      assert app.focus == :datagrid

      app = App.cycle_focus(app, :next)
      assert app.focus == :log

      app = App.cycle_focus(app, :next)
      assert app.focus == :sidebar

      app = App.cycle_focus(app, :prev)
      assert app.focus == :log
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
  end

  describe "Key event dispatching" do
    test "handles tab key to cycle focus" do
      app = App.new(focus: :sidebar)

      app = App.handle_key(app, :tab)
      assert app.focus == :editor

      app = App.handle_key(app, :shift_tab)
      assert app.focus == :sidebar
    end

    test "handles ctrl+1..4 shortcuts for pane focus" do
      app = App.new()

      app = App.handle_key(app, {:ctrl, "1"})
      assert app.focus == :sidebar

      app = App.handle_key(app, {:ctrl, "2"})
      assert app.focus == :editor

      app = App.handle_key(app, {:ctrl, "3"})
      assert app.focus == :datagrid

      app = App.handle_key(app, {:ctrl, "4"})
      assert app.focus == :log
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
      app = App.new(focus: :sidebar, window_size: {120, 40})

      # Click in right editor area (e.g. x: 50, y: 5)
      app = App.handle_mouse(app, {:click, 50, 5})
      assert app.focus == :editor
    end
  end
end
