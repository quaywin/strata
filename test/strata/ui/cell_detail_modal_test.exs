defmodule Strata.UI.Components.CellDetailModalTest do
  use ExUnit.Case, async: true
  alias Strata.UI.Components.CellDetailModal

  describe "new/2 & format detection" do
    test "detects valid JSON string and formats with pretty print" do
      json_str = ~s({"user":{"id":1,"name":"Alice"}})
      modal = CellDetailModal.new(json_str, column: "metadata", row_index: 0)

      assert modal.column == "metadata"
      assert modal.row_index == 0
      assert modal.format == :json
      assert modal.detected_type == :json
      assert modal.formatted_value =~ "\"user\":"
      assert modal.formatted_value =~ "\"name\": \"Alice\""
    end

    test "detects map/list structures and formats as pretty JSON" do
      map_val = %{"status" => "active", "count" => 42}
      modal = CellDetailModal.new(map_val)

      assert modal.format == :json
      assert modal.detected_type == :json
      assert modal.formatted_value =~ "\"status\": \"active\""
    end

    test "treats normal text string as plain text format" do
      text_val = "Hello world from database cell"
      modal = CellDetailModal.new(text_val, column: "description")

      assert modal.column == "description"
      assert modal.format == :text
      assert modal.detected_type == :text
      assert modal.formatted_value == "Hello world from database cell"
    end

    test "handles nil values gracefully" do
      modal = CellDetailModal.new(nil, column: "null_col")
      assert modal.format == :text
      assert modal.formatted_value == "<NULL>"
    end
  end

  describe "handle_key/2 actions" do
    test "toggles format between json, text, and raw when format key pressed" do
      json_str = ~s({"a": 1})
      modal = CellDetailModal.new(json_str)
      assert modal.format == :json

      modal = CellDetailModal.handle_key(modal, "f")
      assert modal.format == :text

      modal = CellDetailModal.handle_key(modal, "f")
      assert modal.format == :raw

      modal = CellDetailModal.handle_key(modal, "f")
      assert modal.format == :json
    end

    test "toggles wrap_lines when w is pressed" do
      modal = CellDetailModal.new("some long text", wrap_lines: true)
      assert modal.wrap_lines == true

      modal = CellDetailModal.handle_key(modal, "w")
      assert modal.wrap_lines == false

      modal = CellDetailModal.handle_key(modal, "w")
      assert modal.wrap_lines == true
    end

    test "scrolls view up and down" do
      multi_line_text = Enum.map(1..50, &"Line #{&1}") |> Enum.join("\n")
      modal = CellDetailModal.new(multi_line_text)
      assert modal.scroll_offset == 0

      modal = CellDetailModal.handle_key(modal, :down)
      assert modal.scroll_offset == 1

      modal = CellDetailModal.handle_key(modal, :page_down)
      assert modal.scroll_offset == 11

      modal = CellDetailModal.handle_key(modal, :up)
      assert modal.scroll_offset == 10
    end
  end

  describe "render/2" do
    test "returns structured map for rendering cell inspector" do
      modal = CellDetailModal.new(%{"test" => 123}, column: "payload")
      rendered = CellDetailModal.render(modal, %{width: 60, height: 20})

      assert rendered.title =~ "CELL INSPECTOR"
      assert rendered.column == "payload"
      assert rendered.format == :json
      assert is_list(rendered.lines)
    end
  end
end
