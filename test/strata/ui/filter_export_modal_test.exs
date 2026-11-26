defmodule Strata.UI.Components.FilterExportModalTest do
  use ExUnit.Case, async: true
  alias Strata.UI.Components.FilterExportModal

  describe "new/2" do
    test "initializes filter modal state" do
      modal = FilterExportModal.new_filter(where: "status = 'active'", order_by: "id DESC", limit: 100)
      assert modal.mode == :filter
      assert modal.where_clause == "status = 'active'"
      assert modal.order_by_clause == "id DESC"
      assert modal.limit == 100
      assert modal.focused_field == :where
    end

    test "initializes export modal state" do
      modal = FilterExportModal.new_export(format: :csv, file_path: "users.csv", scope: :current_page)
      assert modal.mode == :export
      assert modal.format == :csv
      assert modal.file_path == "users.csv"
      assert modal.scope == :current_page
      assert modal.focused_field == :format
    end
  end

  describe "handle_key/2 field navigation and input" do
    test "navigates filter modal fields with tab and shift_tab" do
      modal = FilterExportModal.new_filter()
      assert modal.focused_field == :where

      modal = FilterExportModal.handle_key(modal, :tab)
      assert modal.focused_field == :order_by

      modal = FilterExportModal.handle_key(modal, :tab)
      assert modal.focused_field == :limit

      modal = FilterExportModal.handle_key(modal, :shift_tab)
      assert modal.focused_field == :order_by
    end

    test "cycles export format when format field is focused" do
      modal = FilterExportModal.new_export(format: :csv)
      modal = %{modal | focused_field: :format}

      modal = FilterExportModal.handle_key(modal, :right)
      assert modal.format == :json

      modal = FilterExportModal.handle_key(modal, :right)
      assert modal.format == :sql

      modal = FilterExportModal.handle_key(modal, :right)
      assert modal.format == :csv
    end

    test "cycles export scope when scope field is focused" do
      modal = FilterExportModal.new_export(scope: :all)
      modal = %{modal | focused_field: :scope}

      modal = FilterExportModal.handle_key(modal, :space)
      assert modal.scope == :current_page

      modal = FilterExportModal.handle_key(modal, :space)
      assert modal.scope == :all
    end

    test "types text into focused filter/export inputs" do
      modal = FilterExportModal.new_filter(where: "id > 0", focused_field: :where)

      modal = FilterExportModal.handle_key(modal, " AND age >= 18")
      assert modal.where_clause == "id > 0 AND age >= 18"

      modal = FilterExportModal.handle_key(modal, :backspace)
      assert modal.where_clause == "id > 0 AND age >= 1"
    end

    test "dispatches apply, export, and cancel actions on button activation" do
      filter_apply = %{FilterExportModal.new_filter(where: "id = 1") | focused_field: :apply_button}
      assert {:apply, {:filter, "id = 1", "", nil}, _} = FilterExportModal.handle_key(filter_apply, :enter)

      export_btn = %{FilterExportModal.new_export(format: :json, file_path: "out.json") | focused_field: :export_button}
      assert {:apply, {:export, :json, "out.json", :all}, _} = FilterExportModal.handle_key(export_btn, :enter)

      cancel_btn = %{FilterExportModal.new_filter() | focused_field: :cancel_button}
      assert {:cancel, _} = FilterExportModal.handle_key(cancel_btn, :enter)
    end
  end

  describe "build_filter_sql/2" do
    test "constructs SQL clause from filter settings" do
      modal = FilterExportModal.new_filter(
        where: "status = 'active'",
        order_by: "created_at DESC",
        limit: 50
      )

      sql_clause = FilterExportModal.build_filter_sql(modal, "users")
      assert sql_clause =~ "SELECT * FROM users"
      assert sql_clause =~ "WHERE status = 'active'"
      assert sql_clause =~ "ORDER BY created_at DESC"
      assert sql_clause =~ "LIMIT 50"
    end

    test "handles empty filter fields gracefully" do
      modal = FilterExportModal.new_filter()
      sql_clause = FilterExportModal.build_filter_sql(modal, "users")
      assert sql_clause == "SELECT * FROM users"
    end
  end

  describe "format_export/3" do
    test "formats data as CSV" do
      modal = FilterExportModal.new_export(format: :csv)
      cols = ["id", "name"]
      rows = [["1", "Alice"], ["2", "Bob"]]

      csv = FilterExportModal.format_export(modal, cols, rows, table_name: "users")
      assert csv == "id,name\n1,Alice\n2,Bob\n"
    end

    test "formats data as JSON" do
      modal = FilterExportModal.new_export(format: :json)
      cols = ["id", "name"]
      rows = [["1", "Alice"]]

      json_str = FilterExportModal.format_export(modal, cols, rows)
      decoded = Jason.decode!(json_str)
      assert decoded == [%{"id" => "1", "name" => "Alice"}]
    end

    test "formats data as SQL INSERT statements" do
      modal = FilterExportModal.new_export(format: :sql)
      cols = ["id", "name"]
      rows = [["1", "Alice"], ["2", "Bob"]]

      sql = FilterExportModal.format_export(modal, cols, rows, table_name: "users")
      assert sql =~ "INSERT INTO users (id, name) VALUES ('1', 'Alice');"
      assert sql =~ "INSERT INTO users (id, name) VALUES ('2', 'Bob');"
    end
  end

  describe "render/2" do
    test "returns structured map for rendering filter dialog" do
      modal = FilterExportModal.new_filter()
      rendered = FilterExportModal.render(modal, %{width: 60, height: 20})

      assert rendered.title =~ "FILTER"
      assert rendered.mode == :filter
      assert is_list(rendered.fields)
    end

    test "returns structured map for rendering export dialog" do
      modal = FilterExportModal.new_export()
      rendered = FilterExportModal.render(modal, %{width: 60, height: 20})

      assert rendered.title =~ "EXPORT"
      assert rendered.mode == :export
      assert is_list(rendered.fields)
    end
  end

  describe "cursor movement, clear shortcuts, and UX hints" do
    test "supports cursor movement, mid-string edit/paste, delete, Ctrl+U, and Ctrl+L clear" do
      modal = FilterExportModal.new_filter(where: "id = 10", columns: ["id", "name", "email"])
      assert modal.cursor_pos == 7

      # Move cursor left 2 chars (before "10") and insert ">= " -> "id = >= 10", delete "=" etc.
      moved =
        modal
        |> FilterExportModal.handle_key(:left)
        |> FilterExportModal.handle_key(:left)
        |> FilterExportModal.handle_key("9")

      assert moved.where_clause == "id = 910"
      assert moved.cursor_pos == 6

      after_del = FilterExportModal.handle_key(moved, :delete)
      assert after_del.where_clause == "id = 90"

      after_home = FilterExportModal.handle_key(after_del, :home)
      assert after_home.cursor_pos == 0

      after_clear_line = FilterExportModal.handle_key(after_home, {:ctrl, "u"})
      assert after_clear_line.where_clause == ""
      assert after_clear_line.cursor_pos == 0

      rendered = FilterExportModal.render(moved, %{width: 74, height: 18})
      assert hd(rendered.fields).value == "id = 9▏10"
      assert rendered.status_message =~ "Columns: id, name, email"

      # Clear button or Ctrl+L returns empty filter payload
      clear_btn = %{moved | focused_field: :clear_button}
      assert {:apply, {:filter, "", "", nil}, cleared} = FilterExportModal.handle_key(clear_btn, :enter)
      assert cleared.where_clause == ""
      assert {:apply, {:filter, "", "", nil}, _} = FilterExportModal.handle_key(moved, {:ctrl, "l"})
    end
  end
end
