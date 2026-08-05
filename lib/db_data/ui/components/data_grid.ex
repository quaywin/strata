defmodule DBData.UI.Components.DataGrid do
  @moduledoc """
  Tabular Data Grid component supporting Browsing mode (clean line scrolling)
  and Select mode (cell cursor, highlighting, copy, and cell inspection), matching Caudata's UX design.
  """

  @type cell :: {non_neg_integer(), non_neg_integer()}
  @type mode :: :browsing | :selecting

  defstruct [
    columns: [],
    rows: [],
    selected_cell: {0, 0},
    page: 1,
    page_size: 20,
    total_rows: 0,
    mode: :browsing,
    scroll_offset: 0
  ]

  @type t :: %__MODULE__{
          columns: [String.t()],
          rows: [list()],
          selected_cell: cell(),
          page: pos_integer(),
          page_size: pos_integer(),
          total_rows: non_neg_integer(),
          mode: mode(),
          scroll_offset: non_neg_integer()
        }

  @doc """
  Initializes a new DataGrid struct.
  """
  @spec new([String.t()], [list()], keyword()) :: t()
  def new(columns \\ [], rows \\ [], opts \\ []) do
    page_size = Keyword.get(opts, :page_size, 20)
    page = Keyword.get(opts, :page, 1)
    selected_cell = Keyword.get(opts, :selected_cell, {0, 0})
    mode = Keyword.get(opts, :mode, :browsing)
    scroll_offset = Keyword.get(opts, :scroll_offset, 0)

    %__MODULE__{
      columns: columns,
      rows: rows,
      selected_cell: selected_cell,
      page: page,
      page_size: page_size,
      total_rows: length(rows),
      mode: mode,
      scroll_offset: scroll_offset
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
  Moves cell selection cursor or browsing scroll position according to direction and viewport height.
  """
  @spec move_selection(t(), atom(), pos_integer()) :: t()
  def move_selection(%__MODULE__{} = grid, direction, viewport_h \\ 20) do
    row_count = length(grid.rows)
    col_count = length(grid.columns)

    max_top = max(0, row_count - max(1, viewport_h))
    max_row = max(0, row_count - 1)

    {r, c} = grid.selected_cell
    curr_scroll = grid.scroll_offset || 0

    {new_r, new_scroll} =
      case direction do
        :up ->
          if grid.mode == :browsing do
            s = max(0, curr_scroll - 1)
            nr = max(0, r - 1)
            {nr, s}
          else
            nr = max(0, r - 1)
            ns =
              cond do
                nr < curr_scroll -> nr
                nr >= curr_scroll + viewport_h -> min(max_top, nr - viewport_h + 1)
                true -> curr_scroll
              end

            {nr, ns}
          end

        :down ->
          if grid.mode == :browsing do
            s = min(max_top, curr_scroll + 1)
            nr = min(max_row, r + 1)
            {nr, s}
          else
            nr = min(max_row, r + 1)
            ns =
              cond do
                nr >= curr_scroll + viewport_h -> min(max_top, nr - viewport_h + 1)
                nr < curr_scroll -> nr
                true -> curr_scroll
              end

            {nr, ns}
          end

        :home ->
          {0, 0}

        :end ->
          if grid.mode == :browsing do
            {max_top, max_top}
          else
            {max_row, max_top}
          end

        :page_up ->
          s = max(0, curr_scroll - 10)
          {s, s}

        :page_down ->
          s = min(max_top, curr_scroll + 10)
          {s, s}

        _other ->
          {r, curr_scroll}
      end

    new_c =
      case direction do
        :left -> max(0, c - 1)
        :right -> min(max(0, col_count - 1), c + 1)
        _other -> c
      end

    %{grid | selected_cell: {new_r, new_c}, scroll_offset: new_scroll}
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
  Handles key events for DataGrid depending on mode (:browsing vs :selecting).
  """
  def handle_key(app, %__MODULE__{mode: :browsing} = grid, key) do
    case key do
      :left ->
        app = DBData.UI.App.set_focus(app, :sidebar)
        {app, grid}

      k when k in ["v", "V", "s", "S", :enter, :space] ->
        updated_grid = %{grid | mode: :selecting}

        app =
          Map.put(
            app,
            :status_message,
            "SELECT MODE: Use ↑/↓/←/→ to select cells, [c] copy, [v/Esc] exit to Browsing"
          )

        {app, updated_grid}

      dir when dir in [:up, :down, :right, :home, :end, :page_up, :page_down] ->
        updated_grid = move_selection(grid, dir)
        {app, updated_grid}

      k when k in ["f", "F", "/", {:ctrl, "f"}] ->
        app = DBData.UI.App.push_modal(app, %{type: :filter_modal, title: "Filter Data"})
        {app, grid}

      k when k in ["e", "E", {:ctrl, "e"}] ->
        app = DBData.UI.App.push_modal(app, %{type: :export_modal, title: "Export Data"})
        {app, grid}

      k when k in [:n, "n", "N", {:ctrl, "n"}] ->
        {app, next_page(grid)}

      k when k in [:p, "p", "P", {:ctrl, "p"}] ->
        {app, prev_page(grid)}

      _ ->
        {app, grid}
    end
  end

  def handle_key(app, %__MODULE__{mode: :selecting} = grid, key) do
    case key do
      k when k in [:esc, "v", "V"] ->
        updated_grid = %{grid | mode: :browsing}

        app =
          Map.put(
            app,
            :status_message,
            "BROWSING MODE: Press [v] or [s] or click cell for Select Mode"
          )

        {app, updated_grid}

      k when k in ["c", "C", "y", "Y", {:ctrl, "c"}] ->
        {r, c} = grid.selected_cell
        raw_cell = grid.rows |> Enum.at(r, []) |> Enum.at(c, nil)
        col_name = Enum.at(grid.columns, c, "Cell")
        val_str = DBData.Formatter.sanitize_cell(raw_cell)

        app =
          DBData.UI.App.push_modal(app, %{
            type: :cell_detail_modal,
            title: " 📋 COPIED CELL VALUE (#{col_name}) ",
            content: "Copied value:\n\n#{val_str}\n\n[ Press Esc or Enter to close ]"
          })

        {app, grid}

      k when k in [:enter, :space] ->
        {r, c} = grid.selected_cell
        raw_cell = grid.rows |> Enum.at(r, []) |> Enum.at(c, nil)
        col_name = Enum.at(grid.columns, c, "Cell")
        formatted_detail = DBData.Formatter.format_cell_detail(raw_cell)

        modal_content = """
        Column: #{col_name}  │  Row: #{r + 1}
        ──────────────────────────────────────────────────
        #{formatted_detail}

        ──────────────────────────────────────────────────
        [ Press Esc or Enter to close ]
        """

        app =
          DBData.UI.App.push_modal(app, %{
            type: :cell_detail_modal,
            title: " 🔍 CELL DETAIL INSPECTOR (#{col_name}) ",
            content: modal_content
          })

        {app, grid}

      dir when dir in [:up, :down, :left, :right, :home, :end, :page_up, :page_down] ->
        updated_grid = move_selection(grid, dir)
        {app, updated_grid}

      k when k in ["f", "F", "/", {:ctrl, "f"}] ->
        app = DBData.UI.App.push_modal(app, %{type: :filter_modal, title: "Filter Data"})
        {app, grid}

      k when k in ["e", "E", {:ctrl, "e"}] ->
        app = DBData.UI.App.push_modal(app, %{type: :export_modal, title: "Export Data"})
        {app, grid}

      _ ->
        {app, grid}
    end
  end

  def handle_key(app, grid, _key), do: {app, grid}

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
            is_selected? = grid.mode == :selecting and grid.selected_cell == {r_idx, c_idx}

            if is_selected? do
              "[#{String.trim(str_val)}]" |> String.pad_trailing(width)
            else
              str_val
            end
          end)
          |> Enum.join("│")

        %{
          text: "│" <> cells <> "│",
          selected_row?: grid.mode == :selecting and elem(grid.selected_cell, 0) == r_idx
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
