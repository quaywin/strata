defmodule Strata.UI.Components.DataGridTest do
  use ExUnit.Case, async: true

  alias Strata.UI.App
  alias Strata.UI.Components.DataGrid

  setup do
    columns = ["id", "name", "role", "created_at"]

    rows = [
      [1, "Alice", "Admin", "2026-01-01"],
      [2, "Bob", "Developer", "2026-01-02"],
      [3, "Charlie", "Designer", "2026-01-03"],
      [4, "David", "Tester", "2026-01-04"],
      [5, "Eve", "Manager", "2026-01-05"]
    ]

    grid = DataGrid.new(columns, rows, page_size: 2)
    {:ok, grid: grid, columns: columns, rows: rows}
  end

  describe "Grid cell navigation" do
    test "move_selection moves cell cursor within current page bounds", %{grid: grid} do
      assert grid.selected_cell == {0, 0}

      grid = DataGrid.move_selection(grid, :right)
      assert grid.selected_cell == {0, 1}

      grid = DataGrid.move_selection(grid, :down)
      assert grid.selected_cell == {1, 1}

      grid = DataGrid.move_selection(grid, :left)
      assert grid.selected_cell == {1, 0}

      grid = DataGrid.move_selection(grid, :up)
      assert grid.selected_cell == {0, 0}
    end

    test "move_selection clamps cell cursor within bounds", %{grid: grid} do
      grid = DataGrid.move_selection(grid, :up)
      assert grid.selected_cell == {0, 0}

      grid = DataGrid.move_selection(grid, :left)
      assert grid.selected_cell == {0, 0}
    end
  end

  describe "Pagination controls" do
    test "calculates total pages", %{grid: grid} do
      # 5 rows with page_size 2 => 3 pages
      assert DataGrid.total_pages(grid) == 3
    end

    test "navigates between pages", %{grid: grid} do
      assert grid.page == 1

      grid = DataGrid.next_page(grid)
      assert grid.page == 2
      assert grid.scroll_offset == 2

      grid = DataGrid.next_page(grid)
      assert grid.page == 3
      assert grid.scroll_offset == 4

      grid = DataGrid.next_page(grid)
      assert grid.page == 3

      grid = DataGrid.prev_page(grid)
      assert grid.page == 2
      assert grid.scroll_offset == 2

      grid = DataGrid.first_page(grid)
      assert grid.page == 1
      assert grid.scroll_offset == 0

      grid = DataGrid.last_page(grid)
      assert grid.page == 3
      assert grid.scroll_offset == 4
    end

    test "copying cell in selecting mode writes status message without pushing modal", %{
      grid: grid
    } do
      selecting_grid = %{grid | mode: :selecting, selected_cell: {0, 1}}
      app = App.new(focus: :datagrid, datagrid_state: selecting_grid)

      {updated_app, _} = DataGrid.handle_key(app, selecting_grid, "c")
      assert updated_app.modals == []
      assert updated_app.status_message =~ "Copied name: Alice"

      {row_copied_app, _} = DataGrid.handle_key(app, selecting_grid, "Y")
      assert row_copied_app.status_message =~ "Copied row 1 (4 cols)"

      # Preserves real newlines in multiline printable cells when copying
      multi_grid = %{
        grid
        | mode: :selecting,
          rows: [[1, "line1\nline2", "Admin", "2026-01-01"]],
          selected_cell: {0, 1}
      }

      {multi_app, _} = DataGrid.handle_key(app, multi_grid, "c")
      assert multi_app.status_message =~ "Copied name: line1 ↵ line2"
      assert {:ok, "line1\nline2"} = Strata.Clipboard.paste()

      # Browsing mode also copies active cell directly; empty grid reports no data
      {browse_copy_app, _} = DataGrid.handle_key(app, grid, "C")
      assert browse_copy_app.status_message =~ "Copied id: 1"
      assert {:ok, "1"} = Strata.Clipboard.paste()

      empty_grid = DataGrid.new(["id"], [])
      {empty_app, _} = DataGrid.handle_key(app, empty_grid, "c")
      assert empty_app.status_message =~ "No data to copy"

      # Double-click CellDetailModal supports copying cell value with C / c
      modal_app = %{
        app
        | modals: [Strata.UI.Components.CellDetailModal.new("secret-token", column: "token")]
      }

      copied_modal_app = App.handle_key(modal_app, "C")
      assert copied_modal_app.status_message =~ "Copied token"
      assert {:ok, "secret-token"} = Strata.Clipboard.paste()

      # OSC 52 encoding supports remote terminals (herdr / SSH / tmux)
      assert Strata.Clipboard.encode_osc52("hello") == "\e]52;c;aGVsbG8=\a"

      assert Strata.Clipboard.encode_osc52("hello", tmux: true) ==
               "\ePtmux;\e\e]52;c;aGVsbG8=\a\e\\"
    end

    test "scroll_viewport scrolls scroll_offset immediately in selecting mode and clamps selected_cell" do
      rows = Enum.map(1..30, fn i -> [i, "User #{i}"] end)

      grid =
        DataGrid.new(["id", "name"], rows,
          mode: :selecting,
          selected_cell: {0, 0},
          scroll_offset: 0
        )

      scrolled = DataGrid.scroll_viewport(grid, :down, 10, step: 3)
      assert scrolled.scroll_offset == 3
      assert elem(scrolled.selected_cell, 0) >= 3

      scrolled_up = DataGrid.scroll_viewport(scrolled, :up, 10, step: 3)
      assert scrolled_up.scroll_offset == 0
    end

    test "selecting mode supports g, G, n, and p navigation", %{grid: grid} do
      selecting_grid = %{grid | mode: :selecting, selected_cell: {1, 0}}
      app = App.new(focus: :datagrid, datagrid_state: selecting_grid)

      {_app, paged} = DataGrid.handle_key(app, selecting_grid, :n)
      assert paged.page == 2
      assert paged.scroll_offset == 2

      {_app, bottom} = DataGrid.handle_key(app, paged, "G")
      assert elem(bottom.selected_cell, 0) == 4

      {_app, top} = DataGrid.handle_key(app, bottom, "g")
      assert top.selected_cell == {0, 0}
    end
  end

  describe "DataGrid rendering & App integration" do
    test "renders tabular layout with headers, active page rows, and status", %{grid: grid} do
      app = App.new(focus: :datagrid)
      area = %{x: 0, y: 0, width: 80, height: 20}
      rendered = DataGrid.render(app, area, grid)

      assert rendered.title == "RESULT DATA GRID"
      assert rendered.area == area
      assert is_list(rendered.lines)
      assert length(rendered.lines) > 0
    end

    test "handle_key handles arrow navigation and pagination", %{grid: grid} do
      app = App.new(focus: :datagrid)
      grid_col1 = %{grid | selected_cell: {0, 1}}
      {app_grid, updated_grid} = DataGrid.handle_key(app, grid_col1, :left)
      assert app_grid.focus == :datagrid
      assert updated_grid.selected_cell == {0, 0}

      {_app, updated_grid} = DataGrid.handle_key(app, grid, :down)
      assert updated_grid.selected_cell == {1, 0}

      {_app, updated_grid} = DataGrid.handle_key(app, updated_grid, :n)
      assert updated_grid.page == 2
    end
  end

  describe "Infinite scroll & deduplication helpers" do
    test "append_rows deduplicates new rows against existing rows and updates state", %{
      grid: grid
    } do
      initial_count = length(grid.rows)

      new_rows = [
        # Duplicate row
        [3, "Charlie", "Designer", "2026-01-03"],
        # New unique row
        [6, "Frank", "DevOps", "2026-01-06"]
      ]

      updated_grid = DataGrid.append_rows(grid, new_rows, true)

      assert length(updated_grid.rows) == initial_count + 1
      assert List.last(updated_grid.rows) == [6, "Frank", "DevOps", "2026-01-06"]
      assert updated_grid.total_rows == initial_count + 1
      assert updated_grid.has_more == true
      assert updated_grid.loading_more == false
    end

    test "near_bottom? detects when scroll position is near loaded row threshold", %{grid: grid} do
      large_rows = Enum.map(1..50, fn i -> [i, "User #{i}"] end)
      large_grid = %{grid | rows: large_rows, total_rows: 50}

      # 50 rows with viewport height 10 => max_top = 40. Offset 0 is NOT near bottom.
      refute DataGrid.near_bottom?(large_grid, 10, 2)

      # Move scroll offset near bottom (offset 39 out of max 40)
      near_grid = %{large_grid | scroll_offset: 39}
      assert DataGrid.near_bottom?(near_grid, 10, 2)
    end
  end

  describe "Column width calculation" do
    test "column_widths calculates accurate width based on header length and content max length" do
      cols = ["id", "description"]

      display_rows = [
        [1, "Short"],
        [2, "Very long description that exceeds header length"]
      ]

      widths = DataGrid.column_widths(cols, display_rows)

      # "id": max(4, min(36, len("id")=2, max_cell=1)) = 4
      # "description": max(4, min(36, len("description")=11, max_cell=49)) = 36 (UUID cap)
      assert widths == [4, 36]
    end

    test "column_widths slices columns that fit within max_width for horizontal scroll" do
      cols = ["col1", "col2", "col3", "col4"]
      display_rows = [["a", "b", "c", "d"]]

      # max_width = 18. Each column natural width is 4. 4 + 4 + 4 + 2 spacing = 14 <= 18 => [4, 4, 4]
      widths = DataGrid.column_widths(cols, display_rows, 18)
      assert widths == [4, 4, 4]
    end
  end

  describe "Sorting and staged mutations" do
    test "cycle_sort toggles asc -> desc -> nil and sort_rows_in_memory orders rows cleanly", %{
      grid: grid
    } do
      asc_grid = DataGrid.cycle_sort(grid, "name") |> DataGrid.sort_rows_in_memory()
      assert asc_grid.sort_by == {"name", :asc}

      assert Enum.map(asc_grid.rows, &Enum.at(&1, 1)) == [
               "Alice",
               "Bob",
               "Charlie",
               "David",
               "Eve"
             ]

      desc_grid = DataGrid.cycle_sort(asc_grid, "name") |> DataGrid.sort_rows_in_memory()
      assert desc_grid.sort_by == {"name", :desc}

      assert Enum.map(desc_grid.rows, &Enum.at(&1, 1)) == [
               "Eve",
               "David",
               "Charlie",
               "Bob",
               "Alice"
             ]

      cleared = DataGrid.cycle_sort(desc_grid, "name")
      assert cleared.sort_by == nil
    end

    test "stages cell edits, inserts, deletes, and reverts cleanly", %{grid: grid} do
      g1 = DataGrid.stage_cell_edit(grid, 0, 1, "Alicia")
      assert DataGrid.dirty_count(g1) == 1
      assert g1 |> DataGrid.effective_rows() |> Enum.at(0) |> Enum.at(1) == "Alicia"

      g2 = DataGrid.insert_blank_row(g1)
      assert DataGrid.dirty_count(g2) == 2
      assert length(DataGrid.effective_rows(g2)) == 6
      assert g2.selected_cell == {5, 0}

      # Editing inserted row mutates pending_inserts directly
      g3 = DataGrid.stage_cell_edit(g2, 5, 1, "Frank")
      assert g3 |> DataGrid.effective_rows() |> Enum.at(5) |> Enum.at(1) == "Frank"

      # Marking existing row 1 as deleted increments dirty count; deleting inserted row 5 removes it
      g4 = g3 |> DataGrid.toggle_delete_row(1) |> DataGrid.toggle_delete_row(5)
      assert MapSet.member?(g4.pending_deletes, 1)
      assert g4.pending_inserts == []
      assert DataGrid.dirty_count(g4) == 2

      reverted = DataGrid.revert_staged_changes(g4)
      assert DataGrid.dirty_count(reverted) == 0
      assert DataGrid.effective_rows(reverted) == grid.rows
    end

    test "O(1) effective_row_count, effective_row_at, and effective_rows_slice match effective_rows including fallback",
         %{grid: grid} do
      edited =
        grid
        |> DataGrid.stage_cell_edit(1, 1, "Bobby")
        |> DataGrid.insert_blank_row()
        |> DataGrid.stage_cell_edit(5, 1, "Frank")

      all_eff = DataGrid.effective_rows(edited)
      assert DataGrid.base_row_count(edited) == 5
      assert DataGrid.effective_row_count(edited) == 6
      assert DataGrid.effective_row_at(edited, 1) == Enum.at(all_eff, 1)
      assert DataGrid.effective_row_at(edited, 5) == Enum.at(all_eff, 5)
      assert DataGrid.effective_row_at(edited, 6) == nil
      assert DataGrid.effective_rows_slice(edited, 1, 5) == Enum.slice(all_eff, 1, 5)
      assert DataGrid.effective_rows_slice(edited, 4, 4) == Enum.slice(all_eff, 4, 4)

      # Direct struct override of :rows transparently falls back without stale rows_tuple
      direct_override = %{grid | rows: [[99, "Zoe", "user", "2026-02-01"]], total_rows: 1}
      assert DataGrid.base_row_count(direct_override) == 1
      assert DataGrid.effective_row_at(direct_override, 0) == [99, "Zoe", "user", "2026-02-01"]

      assert DataGrid.effective_rows_slice(direct_override, 0, 5) == [
               [99, "Zoe", "user", "2026-02-01"]
             ]
    end
  end
end
