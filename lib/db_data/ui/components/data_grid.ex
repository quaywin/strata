defmodule DBData.UI.Components.DataGrid do
  @moduledoc """
  Tabular Data Grid component supporting cell cursor navigation, pagination,
  and formatted text rendering.
  """

  @type cell :: {non_neg_integer(), non_neg_integer()}

  defstruct [
    columns: [],
    rows: [],
    selected_cell: {0, 0},
    page: 1,
    page_size: 20,
    total_rows: 0
  ]

  @type t :: %__MODULE__{
          columns: [String.t()],
          rows: [list()],
          selected_cell: cell(),
          page: pos_integer(),
          page_size: pos_integer(),
          total_rows: non_neg_integer()
        }

  @doc """
  Initializes a new DataGrid struct.
  """
  @spec new([String.t()], [list()], keyword()) :: t()
  def new(columns \\ [], rows \\ [], opts \\ []) do
    page_size = Keyword.get(opts, :page_size, 20)
    page = Keyword.get(opts, :page, 1)
    selected_cell = Keyword.get(opts, :selected_cell, {0, 0})

    %__MODULE__{
      columns: columns,
      rows: rows,
      selected_cell: selected_cell,
      page: page,
      page_size: page_size,
      total_rows: length(rows)
    }
  end

  @doc """
  Calculates total number of pages.
  """
  @spec total_pages(t()) :: pos_integer()
  def total_pages(%__MODULE__{total_rows: 0}), do: 1

  def total_pages(%__MODULE__{total_rows: total, page_size: size}) do
    max(1, ceil(total / size))
  end

  @doc """
  Returns slice of rows for current page.
  """
  @spec page_rows(t()) :: [list()]
  def page_rows(%__MODULE__{rows: rows, page: page, page_size: size}) do
    offset = (page - 1) * size
    Enum.slice(rows, offset, size)
  end

  @doc """
  Moves cell selection cursor within page bounds according to direction.
  """
  @spec move_selection(t(), atom()) :: t()
  def move_selection(%__MODULE__{} = grid, direction) do
    p_rows = page_rows(grid)
    row_count = length(p_rows)
    col_count = length(grid.columns)

    {r, c} = grid.selected_cell

    new_cell =
      case direction do
        :up -> {max(0, r - 1), c}
        :down -> {min(max(0, row_count - 1), r + 1), c}
        :left -> {r, max(0, c - 1)}
        :right -> {r, min(max(0, col_count - 1), c + 1)}
        :home -> {r, 0}
        :end -> {r, max(0, col_count - 1)}
        :page_up -> {0, c}
        :page_down -> {max(0, row_count - 1), c}
        _other -> {r, c}
      end

    %{grid | selected_cell: new_cell}
  end

  @doc """
  Sets page index, clamping to valid page range.
  """
  @spec set_page(t(), integer()) :: t()
  def set_page(%__MODULE__{} = grid, page) do
    tot = total_pages(grid)
    clamped_page = max(1, min(tot, page))
    %{grid | page: clamped_page, selected_cell: {0, elem(grid.selected_cell, 1)}}
  end

  @doc """
  Advances to next page.
  """
  @spec next_page(t()) :: t()
  def next_page(grid), do: set_page(grid, grid.page + 1)

  @doc """
  Navigates to previous page.
  """
  @spec prev_page(t()) :: t()
  def prev_page(grid), do: set_page(grid, grid.page - 1)

  @doc """
  Navigates to first page.
  """
  @spec first_page(t()) :: t()
  def first_page(grid), do: set_page(grid, 1)

  @doc """
  Navigates to last page.
  """
  @spec last_page(t()) :: t()
  def last_page(grid), do: set_page(grid, total_pages(grid))

  @doc """
  Handles key events when DataGrid pane is active.
  """
  def handle_key(app, %__MODULE__{} = grid, key) do
    updated_grid =
      case key do
        dir when dir in [:up, :down, :left, :right, :home, :end, :page_up, :page_down] ->
          move_selection(grid, dir)

        :n ->
          next_page(grid)

        :p ->
          prev_page(grid)

        {:ctrl, "n"} ->
          next_page(grid)

        {:ctrl, "p"} ->
          prev_page(grid)

        _other ->
          grid
      end

    {app, updated_grid}
  end

  @doc """
  Renders table layout data structure for given area.
  """
  def render(_app, area, %__MODULE__{} = grid \\ new()) do
    p_rows = page_rows(grid)

    col_widths =
      Enum.map(Enum.with_index(grid.columns), fn {col_name, col_idx} ->
        max_len =
          p_rows
          |> Enum.map(fn row -> to_string(Enum.at(row, col_idx, "")) |> String.length() end)
          |> Enum.max(fn -> 0 end)

        max(String.length(to_string(col_name)), max_len) + 2
      end)

    header_cells =
      Enum.zip(grid.columns, col_widths)
      |> Enum.map(fn {col_name, width} -> String.pad_trailing(to_string(col_name), width) end)
      |> Enum.join("│")

    header_line = "│" <> header_cells <> "│"
    separator_line = String.duplicate("─", String.length(header_line))

    row_lines =
      p_rows
      |> Enum.with_index()
      |> Enum.map(fn {row, r_idx} ->
        cells =
          Enum.zip(row, col_widths)
          |> Enum.with_index()
          |> Enum.map(fn {{val, width}, c_idx} ->
            str_val = String.pad_trailing(to_string(val), width)
            is_selected? = grid.selected_cell == {r_idx, c_idx}

            if is_selected? do
              "[#{String.trim(str_val)}]" |> String.pad_trailing(width)
            else
              str_val
            end
          end)
          |> Enum.join("│")

        %{
          text: "│" <> cells <> "│",
          selected_row?: elem(grid.selected_cell, 0) == r_idx
        }
      end)

    status = "Page #{grid.page} of #{total_pages(grid)} (Total #{grid.total_rows} rows)"

    %{
      title: "RESULT DATA GRID",
      area: area,
      columns: grid.columns,
      page: grid.page,
      total_pages: total_pages(grid),
      total_rows: grid.total_rows,
      selected_cell: grid.selected_cell,
      status: status,
      lines: [
        %{text: header_line, type: :header},
        %{text: separator_line, type: :separator}
      ] ++ row_lines
    }
  end
end
