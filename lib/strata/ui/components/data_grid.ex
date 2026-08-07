defmodule Strata.UI.Components.DataGrid do
  @moduledoc """
  Tabular Data Grid component supporting Browsing mode (clean line scrolling)
  and Select mode (cell cursor, highlighting, copy, and cell inspection), matching Caudata's UX design.
  """

  @type cell :: {non_neg_integer(), non_neg_integer()}
  @type mode :: :browsing | :selecting

  defstruct [
    columns: [],
    rows: [],
    cached_static_widths: [],
    selected_cell: {0, 0},
    page: 1,
    page_size: 20,
    total_rows: 0,
    mode: :browsing,
    scroll_offset: 0,
    col_offset: 0,
    has_more: true,
    loading_more: false,
    batch_size: 100
  ]

  @type t :: %__MODULE__{
          columns: [String.t()],
          rows: [list()],
          cached_static_widths: [pos_integer()],
          selected_cell: cell(),
          page: pos_integer(),
          page_size: pos_integer(),
          total_rows: non_neg_integer(),
          mode: mode(),
          scroll_offset: non_neg_integer(),
          col_offset: non_neg_integer(),
          has_more: boolean(),
          loading_more: boolean(),
          batch_size: pos_integer()
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
    col_offset = Keyword.get(opts, :col_offset, 0)
    has_more = Keyword.get(opts, :has_more, true)
    loading_more = Keyword.get(opts, :loading_more, false)
    batch_size = Keyword.get(opts, :batch_size, 100)

    static_w = static_widths(columns, rows)

    %__MODULE__{
      columns: columns,
      rows: rows,
      cached_static_widths: static_w,
      selected_cell: selected_cell,
      page: page,
      page_size: page_size,
      total_rows: length(rows),
      mode: mode,
      scroll_offset: scroll_offset,
      col_offset: col_offset,
      has_more: has_more,
      loading_more: loading_more,
      batch_size: batch_size
    }
  end

  @doc """
  Appends new rows to grid after deduplicating against existing rows.
  Resets `loading_more: false` and updates `has_more`, `total_rows`, and `cached_static_widths`.
  """
  @spec append_rows(t(), [list()], boolean()) :: t()
  def append_rows(%__MODULE__{} = grid, new_rows, has_more) when is_list(new_rows) do
    existing_set = MapSet.new(grid.rows)
    unique_new = Enum.reject(new_rows, fn r -> MapSet.member?(existing_set, r) end)
    updated_rows = grid.rows ++ unique_new
    static_w = static_widths(grid.columns, updated_rows)

    %{
      grid
      | rows: updated_rows,
        cached_static_widths: static_w,
        total_rows: length(updated_rows),
        has_more: has_more,
        loading_more: false
    }
  end

  @doc """
  Checks if current scroll offset or selection cursor is near the end of loaded rows (default threshold: 25 rows).
  """
  @spec near_bottom?(t(), pos_integer(), non_neg_integer()) :: boolean()
  def near_bottom?(%__MODULE__{total_rows: total, rows: rows, scroll_offset: offset, selected_cell: {r, _}}, viewport_h, threshold \\ 25) do
    row_count = if total > 0, do: total, else: length(rows)
    if row_count == 0 do
      false
    else
      max_top = max(0, row_count - max(1, viewport_h))
      offset >= max(0, max_top - threshold) or r >= max(0, row_count - 1 - threshold)
    end
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
  Moves cell selection cursor or browsing scroll position according to direction, viewport height, and optional max_width.
  """
  @spec move_selection(t(), atom(), pos_integer(), keyword()) :: t()
  def move_selection(%__MODULE__{} = grid, direction, viewport_h \\ 20, opts \\ []) do
    max_width = Keyword.get(opts, :max_width, 999_999)
    row_count = if grid.total_rows > 0, do: grid.total_rows, else: length(grid.rows)
    col_count = length(grid.columns)

    max_top = max(0, row_count - max(1, viewport_h))
    max_row = max(0, row_count - 1)

    {r, c} = grid.selected_cell
    curr_scroll = grid.scroll_offset || 0
    curr_col_scroll = grid.col_offset || 0

    step = Keyword.get(opts, :step, 1)

    {new_r, new_scroll} =
      case direction do
        :up ->
          if grid.mode == :browsing do
            s = max(0, curr_scroll - step)
            nr = max(0, r - step)
            {nr, s}
          else
            nr = max(0, r - step)
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
            s = min(max_top, curr_scroll + step)
            nr = min(max_row, r + step)
            {nr, s}
          else
            nr = min(max_row, r + step)
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

    max_col_off = max_col_offset(grid.columns, grid.rows, max_width)

    {new_col_scroll, new_c} =
      case direction do
        :left ->
          if grid.mode == :browsing do
            ns = max(0, curr_col_scroll - 1)
            nc = max(0, c - 1)
            {ns, nc}
          else
            nc = max(0, c - 1)
            ns = if nc < curr_col_scroll, do: nc, else: curr_col_scroll
            {ns, nc}
          end

        :right ->
          if grid.mode == :browsing do
            # Ensure at least 1 new column appears on the right
            current_widths = column_widths(grid.columns, grid.rows, max_width, curr_col_scroll)
            current_last_visible = curr_col_scroll + length(current_widths) - 1

            ns =
              if curr_col_scroll >= max_col_off do
                curr_col_scroll
              else
                Enum.reduce_while((curr_col_scroll + 1)..max_col_off, curr_col_scroll + 1, fn test_off, _acc ->
                  test_widths = column_widths(grid.columns, grid.rows, max_width, test_off)
                  test_last = test_off + length(test_widths) - 1

                  if test_last > current_last_visible do
                    {:halt, test_off}
                  else
                    {:cont, test_off + 1}
                  end
                end)
                |> min(max_col_off)
              end

            nc = min(max(0, col_count - 1), c + 1)
            {ns, nc}
          else
            nc = min(max(0, col_count - 1), c + 1)
            widths = column_widths(grid.columns, grid.rows, max_width, curr_col_scroll)
            visible_count = length(widths)

            ns =
              if nc >= curr_col_scroll + visible_count do
                if curr_col_scroll >= max_col_off do
                  curr_col_scroll
                else
                  Enum.reduce_while((curr_col_scroll + 1)..max_col_off, max_col_off, fn test_off, _acc ->
                    test_widths = column_widths(grid.columns, grid.rows, max_width, test_off)
                    test_count = length(test_widths)

                    if nc < test_off + test_count do
                      {:halt, test_off}
                    else
                      {:cont, max_col_off}
                    end
                  end)
                end
              else
                curr_col_scroll
              end

            {ns, nc}
          end

        :col_home ->
          {0, 0}

        :col_end ->
          max_c = max(0, col_count - 1)
          {max_col_off, max_c}

        _other ->
          {curr_col_scroll, c}
      end

    %{grid | selected_cell: {new_r, new_c}, scroll_offset: new_scroll, col_offset: new_col_scroll}
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
  Accepts optional `opts` keyword list (e.g. `viewport_h: 30`).
  """
  def handle_key(app, grid, key, opts \\ [])

  def handle_key(app, %__MODULE__{mode: :browsing} = grid, key, opts) do
    vh = Keyword.get(opts, :viewport_h, 20)

    case key do
      k when k in ["v", "V", "s", "S", :enter, :space] ->
        updated_grid = %{grid | mode: :selecting}

        app =
          Map.put(
            app,
            :status_message,
            "SELECT MODE: Use ↑/↓/←/→ to select cells, [c] copy, [v/Esc] exit to Browsing"
          )

        {app, updated_grid}

      dir when dir in [:up, :down, :left, :right, :home, :end, :page_up, :page_down] ->
        updated_grid = move_selection(grid, dir, vh, opts)
        {app, updated_grid}

      k when k in ["h", "H", "j", "J", "k", "K", "l", "L"] ->
        dir =
          case k do
            k when k in ["h", "H"] -> :left
            k when k in ["l", "L"] -> :right
            k when k in ["k", "K"] -> :up
            k when k in ["j", "J"] -> :down
          end

        updated_grid = move_selection(grid, dir, vh, opts)
        {app, updated_grid}

      k when k in ["f", "F", "/", {:ctrl, "f"}] ->
        app = Strata.UI.App.push_modal(app, %{type: :filter_modal, title: "Filter Data"})
        {app, grid}

      k when k in ["e", "E", {:ctrl, "e"}] ->
        app = Strata.UI.App.push_modal(app, %{type: :export_modal, title: "Export Data"})
        {app, grid}

      k when k in [:n, "n", "N", {:ctrl, "n"}] ->
        {app, next_page(grid)}

      k when k in [:p, "p", "P", {:ctrl, "p"}] ->
        {app, prev_page(grid)}

      _ ->
        {app, grid}
    end
  end

  def handle_key(app, %__MODULE__{mode: :selecting} = grid, key, opts) do
    vh = Keyword.get(opts, :viewport_h, 20)

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
        val_str = Strata.Formatter.sanitize_cell(raw_cell)

        app =
          Strata.UI.App.push_modal(app, %{
            type: :cell_detail_modal,
            title: " 📋 COPIED CELL VALUE (#{col_name}) ",
            content: "Copied value:\n\n#{val_str}\n\n[ Press Esc or Enter to close ]"
          })

        {app, grid}

      k when k in [:enter, :space] ->
        {r, c} = grid.selected_cell
        raw_cell = grid.rows |> Enum.at(r, []) |> Enum.at(c, nil)
        col_name = Enum.at(grid.columns, c, "Cell")
        formatted_detail = Strata.Formatter.format_cell_detail(raw_cell)

        modal_content = """
        Column: #{col_name}  │  Row: #{r + 1}
        ──────────────────────────────────────────────────
        #{formatted_detail}

        ──────────────────────────────────────────────────
        [ Press Esc or Enter to close ]
        """

        app =
          Strata.UI.App.push_modal(app, %{
            type: :cell_detail_modal,
            title: " 🔍 CELL DETAIL INSPECTOR (#{col_name}) ",
            content: modal_content
          })

        {app, grid}

      dir when dir in [:up, :down, :left, :right, :home, :end, :page_up, :page_down] ->
        updated_grid = move_selection(grid, dir, vh, opts)
        {app, updated_grid}

      k when k in ["h", "H", "j", "J", "k", "K", "l", "L"] ->
        dir =
          case k do
            k when k in ["h", "H"] -> :left
            k when k in ["l", "L"] -> :right
            k when k in ["k", "K"] -> :up
            k when k in ["j", "J"] -> :down
          end

        updated_grid = move_selection(grid, dir, vh, opts)
        {app, updated_grid}

      k when k in ["f", "F", "/", {:ctrl, "f"}] ->
        app = Strata.UI.App.push_modal(app, %{type: :filter_modal, title: "Filter Data"})
        {app, grid}

      k when k in ["e", "E", {:ctrl, "e"}] ->
        app = Strata.UI.App.push_modal(app, %{type: :export_modal, title: "Export Data"})
        {app, grid}

      _ ->
        {app, grid}
    end
  end

  def handle_key(app, grid, _key, _opts), do: {app, grid}
  @doc """
  Computes or returns cached static width for every column.
  """
  def static_widths(%__MODULE__{cached_static_widths: widths}) when is_list(widths) and widths != [] do
    widths
  end

  def static_widths(%__MODULE__{columns: columns, rows: rows}) do
    static_widths(columns, rows)
  end

  def static_widths(columns, rows) do
    if columns == [] do
      []
    else
      sample_rows = Enum.take(rows, 50)

      Enum.map(Enum.with_index(columns), fn {col_name, col_i} ->
        h_len = String.length(to_string(col_name))

        max_cell_len =
          if sample_rows == [] do
            h_len
          else
            sample_rows
            |> Enum.map(fn row ->
              str = Strata.Formatter.sanitize_cell(Enum.at(row, col_i, ""))
              String.length(str)
            end)
            |> Enum.max(fn -> 0 end)
          end

        # Cap column width between 4 and 36 for clean TUI rendering and full UUID display (36 chars)
        max(4, min(36, max(h_len, max_cell_len)))
      end)
    end
  end

  @doc """
  Maps a relative horizontal pixel/cell coordinate `rel_x` to `{target_local_col, target_col, col_offset}`.
  """
  def col_at_x(%__MODULE__{} = grid, rel_x, max_width) do
    all_w = static_widths(grid)
    max_off = max_col_offset(all_w, max_width)
    col_offset = min(grid.col_offset || 0, max_off)
    col_widths = column_widths_from_all_w(all_w, max_width, col_offset)

    visible_col_count = Enum.count(col_widths, fn w -> w > 0 end)
    active_col_widths = Enum.take(col_widths, visible_col_count)

    target_local_col =
      if active_col_widths != [] do
        last_idx = visible_col_count - 1

        Enum.reduce_while(Enum.with_index(active_col_widths), {0, 0}, fn {w, c_idx}, {acc_x, _} ->
          col_w = if c_idx == last_idx, do: max(w, max_width - acc_x), else: w
          next_x = acc_x + col_w

          if rel_x < next_x do
            {:halt, {acc_x, c_idx}}
          else
            {:cont, {next_x + 1, min(last_idx, c_idx + 1)}}
          end
        end)
        |> elem(1)
      else
        0
      end

    {target_local_col, col_offset + target_local_col, col_offset}
  end

  @doc """
  Returns the maximum col_offset such that the remaining columns
  from that offset still fill or exceed max_width.
  Accepts either {columns, rows} or precomputed `all_w` static widths list.
  """
  def max_col_offset(all_w, max_width) when is_list(all_w) and (all_w == [] or is_integer(hd(all_w))) do
    col_count = length(all_w)

    cond do
      col_count == 0 ->
        0

      max_width >= 999_999 ->
        max(0, col_count - 1)

      true ->
        last_col_idx = col_count - 1

        # Find the smallest offset where the last column is rendered in the viewport
        Enum.find(0..last_col_idx, last_col_idx, fn off ->
          widths = column_widths_from_all_w(all_w, max_width, off)
          off + length(widths) - 1 >= last_col_idx
        end)
    end
  end

  def max_col_offset(columns, rows, max_width) do
    all_w = static_widths(columns, rows)
    max_col_offset(all_w, max_width)
  end

  @doc """
  Returns the visible column widths for the current viewport.
  Slices the static width array from col_offset and fits within max_width.
  Accepts either precomputed `all_w` integer list or {columns, rows}.
  """
  def column_widths(all_w, max_width, col_offset) when is_list(all_w) and (all_w == [] or is_integer(hd(all_w))) do
    column_widths_from_all_w(all_w, max_width, col_offset)
  end

  def column_widths(columns, rows, max_width) do
    column_widths(columns, rows, max_width, 0)
  end

  def column_widths(columns, rows, max_width, col_offset) do
    all_w = static_widths(columns, rows)
    column_widths_from_all_w(all_w, max_width, col_offset)
  end

  def column_widths(columns, rows) do
    column_widths(columns, rows, 999_999, 0)
  end

  def column_widths_from_all_w(all_w, max_width, col_offset) do
    if all_w == [] do
      []
    else
      sliced_widths = Enum.slice(all_w, col_offset, length(all_w))

      if max_width >= 999_999 do
        sliced_widths
      else
        # Step 1: Fit columns at natural width
        {natural_fitting, _rem_w} =
          Enum.reduce_while(sliced_widths, {[], max_width}, fn w, {acc, rem_w} ->
            needed = if acc == [], do: w, else: w + 1

            if rem_w >= needed do
              {:cont, {acc ++ [w], rem_w - needed}}
            else
              {:halt, {acc, rem_w}}
            end
          end)

        natural_count = length(natural_fitting)
        next_col = Enum.at(sliced_widths, natural_count)

        cond do
          natural_count == 0 ->
            [max(1, max_width)]

          # No more columns to add
          next_col == nil ->
            natural_fitting

          # Step 2: If remaining space >= 3, try squeezing in 1 more column
          # rem_w is the leftover from Step 1 PLUS the {:fill,1} stretch on the last column
          # So real available = what the last column would stretch to = rem_w + last_col_natural_width
          # But simpler: just check if all N+1 columns fit when compressed (each >= 4 chars)
          true ->
            candidate = natural_fitting ++ [next_col]
            n = length(candidate)
            spacing = n - 1
            target = max_width - spacing

            # Only try if each column can get at least 4 chars
            if target >= n * 4 do
              total_natural = Enum.sum(candidate)

              if total_natural <= target do
                # Fits at natural width
                candidate
              else
                # Compress proportionally
                compressed =
                  Enum.map(candidate, fn w ->
                    max(4, round(w * target / total_natural))
                  end)

                # Fix rounding overshoot by trimming widest columns
                overshoot = Enum.sum(compressed) - target

                if overshoot > 0 do
                  compressed
                  |> Enum.with_index()
                  |> Enum.sort_by(fn {w, _} -> -w end)
                  |> Enum.reduce({%{}, overshoot}, fn {w, idx}, {map, left} ->
                    trim = min(left, max(0, w - 4))
                    {Map.put(map, idx, w - trim), left - trim}
                  end)
                  |> elem(0)
                  |> then(fn map -> Enum.map(0..(n - 1), &Map.get(map, &1)) end)
                else
                  compressed
                end
              end
            else
              natural_fitting
            end
        end
      end
    end
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
