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
      assert Enum.at(titles, 1) =~ "★ 2: Query 2"

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
  end
end
