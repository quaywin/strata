defmodule Strata.FormatterTest do
  use ExUnit.Case, async: true

  alias Strata.Formatter

  describe "inspect_cell_value/1" do
    test "detects and pretty-prints JSON strings and Elixir maps/lists" do
      assert {:json, pretty} = Formatter.inspect_cell_value(~s({"role":"admin","id":1}))
      assert pretty =~ "\"role\": \"admin\""

      assert {:json, map_json} = Formatter.inspect_cell_value(%{"test" => 123})
      assert map_json =~ "\"test\": 123"
    end

    test "detects nil, printable text, 16-byte UUIDs, binary blobs, and primitives" do
      assert {nil, "<NULL>"} == Formatter.inspect_cell_value(nil)
      assert {:text, "hello world"} == Formatter.inspect_cell_value("hello world")

      uuid_bin = <<1234::32, 0::96>>
      assert {:uuid, uuid_str} = Formatter.inspect_cell_value(uuid_bin)
      assert uuid_str == Formatter.format_uuid(uuid_bin)

      raw_blob = <<0, 1, 2, 255>>
      assert {:binary, hex_str} = Formatter.inspect_cell_value(raw_blob)
      assert hex_str =~ "Binary Data (4 bytes)"

      assert {:primitive, "42"} == Formatter.inspect_cell_value(42)
    end
  end
end
