defmodule Strata.UI.Components.ExportModalTest do
  use ExUnit.Case, async: true
  alias Strata.UI.Components.ExportModal

  describe "new/1" do
    test "initializes export modal state" do
      modal =
        ExportModal.new(format: :csv, file_path: "users.csv", scope: :visible)

      assert modal.format == :csv
      assert modal.file_path == "users.csv"
      assert modal.scope == :visible
      assert modal.focused_field == :format
    end
  end

  describe "handle_key/2 field navigation and input" do
    test "navigates export modal fields with tab and shift_tab" do
      modal = ExportModal.new()
      assert modal.focused_field == :format

      modal = ExportModal.handle_key(modal, :tab)
      assert modal.focused_field == :file_path

      modal = ExportModal.handle_key(modal, :tab)
      assert modal.focused_field == :scope

      modal = ExportModal.handle_key(modal, :shift_tab)
      assert modal.focused_field == :file_path
    end

    test "cycles export format when format field is focused" do
      modal = ExportModal.new(format: :csv)
      modal = %{modal | focused_field: :format}

      modal = ExportModal.handle_key(modal, :right)
      assert modal.format == :json

      modal = ExportModal.handle_key(modal, :right)
      assert modal.format == :sql

      modal = ExportModal.handle_key(modal, :right)
      assert modal.format == :csv
    end

    test "cycles export scope when scope field is focused" do
      modal = ExportModal.new(scope: :all)
      modal = %{modal | focused_field: :scope}

      modal = ExportModal.handle_key(modal, :space)
      assert modal.scope == :visible

      modal = ExportModal.handle_key(modal, :space)
      assert modal.scope == :all
    end

    test "types text and supports cursor movement into file_path field" do
      modal = ExportModal.new(file_path: "users.csv", focused_field: :file_path)
      assert modal.cursor_pos == 9

      moved =
        modal
        |> ExportModal.handle_key(:left)
        |> ExportModal.handle_key(:left)
        |> ExportModal.handle_key(:left)
        |> ExportModal.handle_key(:left)
        |> ExportModal.handle_key("_v2")

      assert moved.file_path == "users_v2.csv"

      after_del = ExportModal.handle_key(moved, :delete)
      assert after_del.file_path == "users_v2csv"

      after_home = ExportModal.handle_key(after_del, :home)
      assert after_home.cursor_pos == 0

      after_clear_line = ExportModal.handle_key(after_home, {:ctrl, "u"})
      assert after_clear_line.file_path == ""
      assert after_clear_line.cursor_pos == 0
    end

    test "dispatches export and cancel actions on button activation" do
      export_btn = %{
        ExportModal.new(format: :json, file_path: "out.json")
        | focused_field: :export_button
      }

      assert {:apply, {:export, :json, "out.json", :all}, _} =
               ExportModal.handle_key(export_btn, :enter)

      cancel_btn = %{ExportModal.new() | focused_field: :cancel_button}
      assert {:cancel, _} = ExportModal.handle_key(cancel_btn, :enter)
    end
  end

  describe "format_export/3" do
    test "formats data as CSV" do
      modal = ExportModal.new(format: :csv)
      cols = ["id", "name"]
      rows = [["1", "Alice"], ["2", "Bob"]]

      csv = ExportModal.format_export(modal, cols, rows, table_name: "users")
      assert csv == "id,name\n1,Alice\n2,Bob\n"
    end

    test "formats data as JSON" do
      modal = ExportModal.new(format: :json)
      cols = ["id", "name"]
      rows = [["1", "Alice"]]

      json_str = ExportModal.format_export(modal, cols, rows)
      decoded = Jason.decode!(json_str)
      assert decoded == [%{"id" => "1", "name" => "Alice"}]
    end

    test "formats data as SQL INSERT statements" do
      modal = ExportModal.new(format: :sql)
      cols = ["id", "name"]
      rows = [["1", "Alice"], ["2", "Bob"]]

      sql = ExportModal.format_export(modal, cols, rows, table_name: "users")
      assert sql =~ "INSERT INTO users (id, name) VALUES ('1', 'Alice');"
      assert sql =~ "INSERT INTO users (id, name) VALUES ('2', 'Bob');"
    end
  end

  describe "render/2" do
    test "returns structured map for rendering export dialog" do
      modal = ExportModal.new()
      rendered = ExportModal.render(modal, %{width: 60, height: 20})

      assert rendered.title =~ "EXPORT"
      assert is_list(rendered.fields)
    end
  end
end
