defmodule DBData.UI.Components.LogPaneTest do
  use ExUnit.Case, async: true

  alias DBData.UI.App
  alias DBData.UI.Components.LogPane

  setup do
    log_state = LogPane.new()
    {:ok, log_state: log_state}
  end

  describe "Log state management" do
    test "add_entry appends entry to log state", %{log_state: state} do
      state = LogPane.add_entry(state, level: :info, message: "Query executed in 5.2ms")

      assert length(state.entries) == 1
      entry = List.first(state.entries)
      assert entry.level == :info
      assert entry.message == "Query executed in 5.2ms"
      assert entry.timestamp != nil
    end

    test "auto-scrolls to bottom when auto_scroll? is true", %{log_state: state} do
      state =
        state
        |> LogPane.add_entry(level: :info, message: "Log 1")
        |> LogPane.add_entry(level: :info, message: "Log 2")

      assert state.auto_scroll? == true
    end
  end

  describe "Scroll navigation" do
    test "scroll changes offset and adjusts auto_scroll?", %{log_state: state} do
      state =
        1..10
        |> Enum.reduce(state, fn idx, acc ->
          LogPane.add_entry(acc, level: :info, message: "Log line #{idx}")
        end)

      # Scroll up disables auto-scroll
      state = LogPane.scroll(state, :up)
      assert state.auto_scroll? == false
      assert state.scroll_offset > 0

      # Scroll bottom re-enables auto-scroll
      state = LogPane.scroll(state, :bottom)
      assert state.auto_scroll? == true
    end
  end

  describe "LogPane rendering & App integration" do
    test "renders log console view", %{log_state: state} do
      state = LogPane.add_entry(state, level: :error, message: "Connection timeout")
      app = App.new(focus: :log)
      area = %{x: 0, y: 0, width: 80, height: 10}

      rendered = LogPane.render(app, area, state)

      assert rendered.title == "QUERY LOGS & CONSOLE STATS"
      assert rendered.area == area
      assert is_list(rendered.lines)
      assert length(rendered.lines) > 0
      assert Enum.any?(rendered.lines, &String.contains?(&1.text, "[ERROR] Connection timeout"))
    end

    test "handle_key handles log pane scrolling", %{log_state: state} do
      state = LogPane.add_entry(state, level: :info, message: "Line 1")
      app = App.new(focus: :log)

      {_app, updated_state} = LogPane.handle_key(app, state, :up)
      assert updated_state.auto_scroll? == false
    end
  end
end
