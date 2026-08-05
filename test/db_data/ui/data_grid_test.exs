defmodule DBData.UI.Components.DataGridTest do
  use ExUnit.Case, async: true

  alias DBData.UI.App
  alias DBData.UI.Components.DataGrid

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
      
      {_app, updated_grid} = DataGrid.handle_key(app, grid, :down)
      assert updated_grid.selected_cell == {1, 0}

      {_app, updated_grid} = DataGrid.handle_key(app, updated_grid, :n)
      assert updated_grid.page == 2
    end
  end
end
