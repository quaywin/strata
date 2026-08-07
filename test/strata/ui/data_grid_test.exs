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

      grid = DataGrid.next_page(grid)
      assert grid.page == 3

      grid = DataGrid.next_page(grid)
      assert grid.page == 3

      grid = DataGrid.prev_page(grid)
      assert grid.page == 2

      grid = DataGrid.first_page(grid)
      assert grid.page == 1

      grid = DataGrid.last_page(grid)
      assert grid.page == 3
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
    test "append_rows deduplicates new rows against existing rows and updates state", %{grid: grid} do
      initial_count = length(grid.rows)

      new_rows = [
        [3, "Charlie", "Designer", "2026-01-03"], # Duplicate row
        [6, "Frank", "DevOps", "2026-01-06"]      # New unique row
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
end
