defmodule Strata.UI.Components.SQLEditorTest do
  use ExUnit.Case, async: true

  alias Strata.UI.App
  alias Strata.UI.Components.SQLEditor

  describe "SQL Syntax Highlighting" do
    test "tokenize identifies SQL keywords" do
      tokens = SQLEditor.tokenize("SELECT * FROM users WHERE status = 'active';")

      types = Enum.map(tokens, & &1.type)
      assert :keyword in types
      assert :identifier in types
      assert :string in types
      assert :operator in types
      assert :punctuation in types

      select_token = Enum.find(tokens, &(&1.text == "SELECT"))
      assert select_token.type == :keyword

      from_token = Enum.find(tokens, &(&1.text == "FROM"))
      assert from_token.type == :keyword

      string_token = Enum.find(tokens, &(&1.text == "'active'"))
      assert string_token.type == :string
    end

    test "tokenize identifies numbers and comments" do
      tokens = SQLEditor.tokenize("SELECT 123, 45.67 -- query count")

      number_token = Enum.find(tokens, &(&1.text == "123"))
      assert number_token.type == :number

      float_token = Enum.find(tokens, &(&1.text == "45.67"))
      assert float_token.type == :number

      comment_token = Enum.find(tokens, &String.starts_with?(&1.text, "--"))
      assert comment_token.type == :comment
    end
  end

  describe "Editor text manipulation" do
    test "insert_text inserts string at cursor position" do
      content = "SELECT 1"
      {updated, new_cursor} = SQLEditor.insert_text(content, {0, 8}, ";")
      assert updated == "SELECT 1;"
      assert new_cursor == {0, 9}
    end

    test "insert_text splits line when inserting newline" do
      content = "SELECT 1; FROM users"
      {updated, new_cursor} = SQLEditor.insert_text(content, {0, 9}, "\n")
      assert updated == "SELECT 1;\n FROM users"
      assert new_cursor == {1, 0}
    end

    test "backspace deletes character before cursor" do
      content = "SELECT"
      {updated, new_cursor} = SQLEditor.backspace(content, {0, 6})
      assert updated == "SELEC"
      assert new_cursor == {0, 5}
    end

    test "backspace joins lines when at start of line" do
      content = "SELECT\nFROM"
      {updated, new_cursor} = SQLEditor.backspace(content, {1, 0})
      assert updated == "SELECTFROM"
      assert new_cursor == {0, 6}
    end

    test "delete_char deletes character at cursor" do
      content = "SELECT"
      {updated, new_cursor} = SQLEditor.delete_char(content, {0, 0})
      assert updated == "ELECT"
      assert new_cursor == {0, 0}
    end

    test "delete_char joins lines when at end of line" do
      content = "SELECT\nFROM"
      {updated, new_cursor} = SQLEditor.delete_char(content, {0, 6})
      assert updated == "SELECTFROM"
      assert new_cursor == {0, 6}
    end
  end

  describe "Cursor navigation" do
    test "moves cursor left, right, up, down, home, end" do
      content = "SELECT *\nFROM users"

      assert SQLEditor.move_cursor(content, {0, 0}, :right) == {0, 1}
      assert SQLEditor.move_cursor(content, {0, 1}, :left) == {0, 0}
      assert SQLEditor.move_cursor(content, {0, 2}, :down) == {1, 2}
      assert SQLEditor.move_cursor(content, {1, 2}, :up) == {0, 2}
      assert SQLEditor.move_cursor(content, {0, 4}, :home) == {0, 0}
      assert SQLEditor.move_cursor(content, {0, 2}, :end) == {0, 8}
    end

    test "clamps cursor within bounds" do
      content = "abc"
      assert SQLEditor.move_cursor(content, {0, 0}, :left) == {0, 0}
      assert SQLEditor.move_cursor(content, {0, 3}, :right) == {0, 3}
      assert SQLEditor.move_cursor(content, {0, 0}, :up) == {0, 0}
      assert SQLEditor.move_cursor(content, {0, 0}, :down) == {0, 0}
    end
  end

  describe "SQLEditor App Integration" do
    test "handle_key typing updates active tab content" do
      app = App.new(focus: :editor)

      app = SQLEditor.handle_key(app, {:char, "A"})
      active = Enum.find(app.tabs, &(&1.id == app.active_tab_id))
      assert String.contains?(active.content, "A")
    end

    test "render returns structured view map with tab titles" do
      app = App.new(focus: :editor)
      area = %{x: 0, y: 0, width: 80, height: 20}
      rendered = SQLEditor.render(app, area)

      assert rendered.title == "SQL EDITOR"
      assert rendered.area == area
      assert is_list(rendered.lines)
      assert rendered.active_tab != nil
      assert is_list(rendered.tab_titles)
      assert rendered.active_index == 0
    end

    test "tab_titles and active_tab_index calculate tab metadata correctly" do
      app = App.new(focus: :editor)
      app = App.open_tab(app, name: "Query 2")

      titles = SQLEditor.tab_titles(app)
      assert length(titles) == 2
      assert Enum.at(titles, 1) == "2: Query 2"
      refute String.contains?(Enum.at(titles, 1), "★")

      assert SQLEditor.active_tab_index(app) == 1
    end

    test "handle_key with :tab inserts two spaces" do
      app = App.new(focus: :editor)
      app = SQLEditor.handle_key(app, :tab)
      active = Enum.find(app.tabs, &(&1.id == app.active_tab_id))
      assert active.content == "  "
    end

    test "typing word activates completion state and Tab applies suggestion" do
      app = App.new(focus: :editor)
      app = SQLEditor.handle_key(app, "S")
      app = SQLEditor.handle_key(app, "E")

      active = Enum.find(app.tabs, &(&1.id == app.active_tab_id))
      comp = active.completion
      assert comp.active? == true
      assert length(comp.suggestions) > 0

      # Down arrow moves selection
      app = SQLEditor.handle_key(app, :down)
      active = Enum.find(app.tabs, &(&1.id == app.active_tab_id))
      assert active.completion.selected_index == 1

      # Tab applies selected suggestion
      app = SQLEditor.handle_key(app, :tab)
      active = Enum.find(app.tabs, &(&1.id == app.active_tab_id))
      assert active.content =~ "SET"
      assert active.completion.active? == false
    end

    test "Enter and Tab accept selected suggestion when popup is open; Esc closes popup so Enter inserts newline" do
      app =
        App.new(focus: :editor)
        |> SQLEditor.handle_key("S")
        |> SQLEditor.handle_key("E")

      active = Enum.find(app.tabs, &(&1.id == app.active_tab_id))
      assert active.completion.active? == true

      # Enter accepts highlighted suggestion when completion popup is open
      app_enter = SQLEditor.handle_key(app, :down) |> SQLEditor.handle_key(:enter)
      active_enter = Enum.find(app_enter.tabs, &(&1.id == app_enter.active_tab_id))
      assert active_enter.content == "SET"
      assert active_enter.completion.active? == false

      # Esc dismisses completion, then Enter inserts newline
      app_esc = SQLEditor.handle_key(app, :esc)
      app_nl = SQLEditor.handle_key(app_esc, :enter)
      active_nl = Enum.find(app_nl.tabs, &(&1.id == app_nl.active_tab_id))
      assert active_nl.content == "SE\n"
      assert active_nl.completion.active? == false

      # Left arrow moving back onto "SE" must NOT force completion open
      app_left = SQLEditor.handle_key(app_nl, :left)
      active_after_left = Enum.find(app_left.tabs, &(&1.id == app_left.active_tab_id))
      assert active_after_left.completion.active? == false
    end

    test "Ctrl+Space opens clause-aware suggestions and linting detects bad columns or unclosed parens" do
      Strata.DataStore.put_columns_cache("c_ed_test", "public", "users", ["id", "email"])

      app =
        App.new(focus: :editor)
        |> put_in([Access.key(:tabs), Access.at(0), :profile_id], "c_ed_test")
        |> put_in([Access.key(:tabs), Access.at(0), :content], "SELECT * FROM users u WHERE ")
        |> put_in([Access.key(:tabs), Access.at(0), :cursor], {0, 28})

      opened = SQLEditor.handle_key(app, {:ctrl, "space"})
      tab = Enum.find(opened.tabs, &(&1.id == opened.active_tab_id))
      assert tab.completion.active? == true

      assert Enum.any?(
               tab.completion.suggestions,
               &(&1.insert_text == "u.email" and &1.detail == "users → email")
             )

      # Typing bad column produces diagnostic
      bad_app = SQLEditor.handle_key(opened, {:paste, "u.missing_col"})
      bad_tab = Enum.find(bad_app.tabs, &(&1.id == bad_app.active_tab_id))
      assert Enum.any?(bad_tab.diagnostics, &(&1.message =~ "Column 'missing_col' not found"))
    end
  end

  describe "Visual wrapping without inserting newlines" do
    test "visual_layout wraps long lines with continuation gutter and preserves logical content" do
      long_sql = "SELECT first_col, second_col, third_col FROM my_table;"
      layout = SQLEditor.visual_layout(long_sql, {0, 25}, 20)

      assert length(layout.visual_lines) == 3
      [vl0, vl1, vl2] = layout.visual_lines

      assert vl0.continued? == false
      assert vl0.prefix == "  1 │ "
      assert vl0.text == "SELECT first_col, se"

      assert vl1.continued? == true
      assert vl1.prefix == "    │ "
      assert vl1.text == "cond_col, third_col "
      assert vl1.has_cursor? == true
      assert vl1.cursor_col == 5

      assert vl2.continued? == true
      assert vl2.text == "FROM my_table;"
      assert layout.cursor_v_pos == {1, 5}
    end

    test "move_cursor_visual and handle_key move up/down across wrapped visual rows" do
      long_sql = String.duplicate("a", 25) <> "\nSELECT 1;"
      assert SQLEditor.move_cursor_visual(long_sql, {0, 5}, :down, 20) == {0, 25}
      assert SQLEditor.move_cursor_visual(long_sql, {0, 25}, :up, 20) == {0, 5}
      assert SQLEditor.move_cursor_visual(long_sql, {0, 22}, :down, 20) == {1, 2}

      app =
        App.new(window_size: {40, 20}, active_view: :query_view, focus: :editor)
        |> put_in(
          [Access.key(:tabs), Access.at(0), :content],
          "SELECT alpha_column, beta_column, gamma_column FROM users;"
        )
        |> put_in([Access.key(:tabs), Access.at(0), :cursor], {0, 4})

      ed_area = Strata.UI.Renderer.layout(app.window_size, :query_view).editor
      %{code_width: cw} = SQLEditor.editor_metrics(hd(app.tabs).content, ed_area)
      assert cw < String.length(hd(app.tabs).content)

      moved_down = SQLEditor.handle_key(app, :down)
      assert hd(moved_down.tabs).cursor == {0, cw + 4}

      moved_up = SQLEditor.handle_key(moved_down, :up)
      assert hd(moved_up.tabs).cursor == {0, 4}
    end
  end
end
