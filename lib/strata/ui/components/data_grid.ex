defmodule Strata.UI.Components.DataGrid do
  @moduledoc """
  Tabular Data Grid component supporting Browsing mode (clean line scrolling)
  and Select mode (cell cursor, highlighting, copy, and cell inspection), matching Caudata's UX design.
  """

  @type cell :: {non_neg_integer(), non_neg_integer()}
  @type mode :: :browsing | :selecting

  defstruct columns: [],
            rows: [],
            rows_tuple: nil,
            cached_static_widths: [],
            selected_cell: {0, 0},
            total_rows: 0,
            total_db_rows: nil,
            mode: :browsing,
            view_mode: :data,
            scroll_offset: 0,
            col_offset: 0,
            has_more: true,
            loading_more: false,
            batch_size: 100,
            sort_by: nil,
            primary_keys: [],
            pending_edits: %{},
            pending_inserts: [],
            pending_deletes: MapSet.new(),
            editing_cell: nil

  @type t :: %__MODULE__{
          columns: [String.t()],
          rows: [list()],
          rows_tuple: tuple() | nil,
          cached_static_widths: [pos_integer()],
          selected_cell: cell(),
          total_rows: non_neg_integer(),
          total_db_rows: non_neg_integer() | nil,
          mode: mode(),
          view_mode: :data | :structure,
          scroll_offset: non_neg_integer(),
          col_offset: non_neg_integer(),
          has_more: boolean(),
          loading_more: boolean(),
          batch_size: pos_integer(),
          sort_by: {String.t(), :asc | :desc} | nil,
          primary_keys: [String.t()],
          pending_edits: map(),
          pending_inserts: [list()],
          pending_deletes: MapSet.t(),
          editing_cell: cell() | nil
        }

  @doc """
  Initializes a new DataGrid struct.
  """
  @spec new([String.t()], [list()], keyword()) :: t()
  def new(columns \\ [], rows \\ [], opts \\ []) do
    selected_cell = Keyword.get(opts, :selected_cell, {0, 0})
    mode = Keyword.get(opts, :mode, :browsing)
    scroll_offset = Keyword.get(opts, :scroll_offset, 0)
    col_offset = Keyword.get(opts, :col_offset, 0)
    has_more = Keyword.get(opts, :has_more, true)
    loading_more = Keyword.get(opts, :loading_more, false)
    batch_size = Keyword.get(opts, :batch_size, 100)
    total_db_rows = Keyword.get(opts, :total_db_rows)
    sort_by = Keyword.get(opts, :sort_by)
    view_mode = Keyword.get(opts, :view_mode, :data)
    primary_keys = Keyword.get(opts, :primary_keys, [])

    static_w = static_widths(columns, rows)

    %__MODULE__{
      columns: columns,
      rows: rows,
      rows_tuple: List.to_tuple(rows),
      cached_static_widths: static_w,
      selected_cell: selected_cell,
      total_rows: length(rows),
      total_db_rows: total_db_rows,
      mode: mode,
      view_mode: view_mode,
      scroll_offset: scroll_offset,
      col_offset: col_offset,
      has_more: has_more,
      loading_more: loading_more,
      batch_size: batch_size,
      sort_by: sort_by,
      primary_keys: primary_keys
    }
  end

  @doc """
  Returns total count of staged changes (cell edits + inserts + deletes).
  """
  @spec dirty_count(t()) :: non_neg_integer()
  def dirty_count(%__MODULE__{} = grid) do
    map_size(grid.pending_edits) + length(grid.pending_inserts) +
      MapSet.size(grid.pending_deletes)
  end

  @doc """
  Returns all display rows combining loaded `rows`, overlaid `pending_edits`, and
  staged `pending_inserts`.
  """
  @spec effective_rows(t()) :: [list()]
  def effective_rows(%__MODULE__{rows: rows, pending_edits: edits, pending_inserts: inserts}) do
    base_rows =
      if map_size(edits) == 0 do
        rows
      else
        edits_by_row =
          Enum.group_by(edits, fn {{r_idx, _c_idx}, _val} -> r_idx end, fn {{_r_idx, c_idx}, val} ->
            {c_idx, val.new}
          end)

        rows
        |> Enum.with_index()
        |> Enum.map(fn {row, r_idx} ->
          case Map.get(edits_by_row, r_idx) do
            nil ->
              row

            col_updates ->
              Enum.reduce(col_updates, row, fn {c_idx, new_val}, acc ->
                List.replace_at(acc, c_idx, new_val)
              end)
          end
        end)
      end

    if inserts == [], do: base_rows, else: base_rows ++ inserts
  end

  @doc """
  Returns base row count (excluding `pending_inserts`) in O(1) when `rows_tuple` is valid.
  """
  @spec base_row_count(t()) :: non_neg_integer()
  def base_row_count(%__MODULE__{rows_tuple: rt} = grid) do
    if rows_tuple_valid?(grid), do: tuple_size(rt), else: length(grid.rows)
  end

  @doc """
  Returns total effective row count (`base_row_count + length(pending_inserts)`).
  """
  @spec effective_row_count(t()) :: non_neg_integer()
  def effective_row_count(%__MODULE__{pending_inserts: inserts} = grid) do
    base_row_count(grid) + length(inserts)
  end

  @doc """
  Returns the single effective row at 0-based `abs_r` in O(1) (with pending edits overlaid),
  or `nil` if out of bounds.
  """
  @spec effective_row_at(t(), integer()) :: list() | nil
  def effective_row_at(%__MODULE__{} = grid, abs_r) when is_integer(abs_r) and abs_r >= 0 do
    base_len = base_row_count(grid)

    if abs_r < base_len do
      row =
        if rows_tuple_valid?(grid) do
          elem(grid.rows_tuple, abs_r)
        else
          Enum.at(grid.rows, abs_r)
        end

      if row, do: apply_row_edits(row, abs_r, grid.pending_edits), else: nil
    else
      Enum.at(grid.pending_inserts, abs_r - base_len)
    end
  end

  def effective_row_at(_grid, _abs_r), do: nil

  @doc """
  Returns only the visible `count` effective rows starting at `start_idx`, avoiding
  O(N) traversal and list copying on large datasets.
  """
  @spec effective_rows_slice(t(), non_neg_integer(), integer()) :: [list()]
  def effective_rows_slice(%__MODULE__{} = _grid, _start_idx, count) when count <= 0, do: []

  def effective_rows_slice(%__MODULE__{} = grid, start_idx, count) do
    start_idx = max(0, start_idx)
    base_len = base_row_count(grid)
    inserts = grid.pending_inserts
    total_len = base_len + length(inserts)

    if start_idx >= total_len do
      []
    else
      end_idx = min(total_len - 1, start_idx + count - 1)
      base_end = min(base_len - 1, end_idx)

      base_slice =
        if start_idx <= base_end do
          raw_slice =
            if rows_tuple_valid?(grid) do
              rt = grid.rows_tuple
              for i <- start_idx..base_end, do: elem(rt, i)
            else
              Enum.slice(grid.rows, start_idx, base_end - start_idx + 1)
            end

          if map_size(grid.pending_edits) == 0 do
            raw_slice
          else
            edits_by_row =
              Enum.reduce(grid.pending_edits, %{}, fn
                {{r_idx, c_idx}, %{new: new_val}}, acc
                when r_idx >= start_idx and r_idx <= base_end ->
                  Map.update(acc, r_idx, [{c_idx, new_val}], &[{c_idx, new_val} | &1])

                _, acc ->
                  acc
              end)

            if map_size(edits_by_row) == 0 do
              raw_slice
            else
              raw_slice
              |> Enum.with_index(start_idx)
              |> Enum.map(fn {row, r_idx} ->
                case Map.get(edits_by_row, r_idx) do
                  nil ->
                    row

                  col_updates ->
                    Enum.reduce(col_updates, row, fn {c_idx, new_val}, acc ->
                      List.replace_at(acc, c_idx, new_val)
                    end)
                end
              end)
            end
          end
        else
          []
        end

      needed_inserts = end_idx - max(start_idx, base_len) + 1

      insert_slice =
        if end_idx >= base_len and needed_inserts > 0 and inserts != [] do
          ins_start = max(0, start_idx - base_len)
          Enum.slice(inserts, ins_start, needed_inserts)
        else
          []
        end

      if insert_slice == [], do: base_slice, else: base_slice ++ insert_slice
    end
  end

  defp rows_tuple_valid?(%__MODULE__{
         rows: rows,
         rows_tuple: rows_tuple,
         total_rows: total_rows,
         pending_inserts: inserts
       })
       when is_tuple(rows_tuple) do
    t_size = tuple_size(rows_tuple)

    cond do
      rows == [] and t_size == 0 ->
        true

      rows != [] and t_size > 0 and hd(rows) == elem(rows_tuple, 0) ->
        total_rows == 0 or total_rows == t_size + length(inserts)

      true ->
        false
    end
  end

  defp rows_tuple_valid?(_grid), do: false

  defp apply_row_edits(row, _abs_r, edits) when map_size(edits) == 0, do: row

  defp apply_row_edits(row, abs_r, edits) do
    Enum.reduce(edits, row, fn
      {{^abs_r, c_idx}, %{new: new_val}}, acc -> List.replace_at(acc, c_idx, new_val)
      _, acc -> acc
    end)
  end

  @doc """
  Cycles sort state for column at `col_idx` or named `col_name`:
  `nil -> {col, :asc} -> {col, :desc} -> nil`.
  """
  @spec cycle_sort(t(), non_neg_integer() | String.t()) :: t()
  def cycle_sort(%__MODULE__{columns: cols} = grid, col_name) when is_binary(col_name) do
    case Enum.find_index(cols, &(to_string(&1) == col_name)) do
      nil -> grid
      idx -> cycle_sort(grid, idx)
    end
  end

  def cycle_sort(%__MODULE__{columns: cols} = grid, col_idx) when is_integer(col_idx) do
    case Enum.at(cols, col_idx) do
      nil ->
        grid

      col_name ->
        next_sort =
          case grid.sort_by do
            {^col_name, :asc} -> {col_name, :desc}
            {^col_name, :desc} -> nil
            _ -> {col_name, :asc}
          end

        %{grid | sort_by: next_sort}
    end
  end

  @doc """
  Sorts `grid.rows` in-memory according to `grid.sort_by`.
  """
  @spec sort_rows_in_memory(t()) :: t()
  def sort_rows_in_memory(%__MODULE__{sort_by: nil} = grid), do: grid

  def sort_rows_in_memory(%__MODULE__{sort_by: {col_name, dir}, columns: cols, rows: rows} = grid) do
    case Enum.find_index(cols, &(&1 == col_name)) do
      nil ->
        grid

      col_idx ->
        sorted =
          Enum.sort_by(
            rows,
            fn row ->
              val = Enum.at(row, col_idx)
              if is_nil(val), do: {1, ""}, else: {0, sortable_value(val)}
            end,
            if(dir == :asc, do: :asc, else: :desc)
          )

        %{
          grid
          | rows: sorted,
            rows_tuple: List.to_tuple(sorted),
            scroll_offset: 0,
            selected_cell: {0, elem(grid.selected_cell, 1)}
        }
    end
  end

  defp sortable_value(v) when is_number(v), do: v
  defp sortable_value(v) when is_binary(v), do: String.downcase(v)
  defp sortable_value(v), do: Strata.Formatter.sanitize_cell(v)

  @doc """
  Stages an edited cell value into `pending_edits` or updates a staged insert row.
  """
  @spec stage_cell_edit(t(), non_neg_integer(), non_neg_integer(), term()) :: t()
  def stage_cell_edit(%__MODULE__{} = grid, r_idx, c_idx, new_value) do
    base_len = length(grid.rows)

    if r_idx >= base_len do
      ins_idx = r_idx - base_len

      updated_inserts =
        List.update_at(grid.pending_inserts, ins_idx, fn row ->
          List.replace_at(row, c_idx, new_value)
        end)

      %{grid | pending_inserts: updated_inserts, editing_cell: nil}
    else
      orig_value = grid.rows |> Enum.at(r_idx, []) |> Enum.at(c_idx)

      pending_edits =
        if new_value == orig_value do
          Map.delete(grid.pending_edits, {r_idx, c_idx})
        else
          Map.put(grid.pending_edits, {r_idx, c_idx}, %{orig: orig_value, new: new_value})
        end

      %{grid | pending_edits: pending_edits, editing_cell: nil}
    end
  end

  @doc """
  Appends a blank staged insert row and moves selection to its first cell.
  """
  @spec insert_blank_row(t()) :: t()
  def insert_blank_row(%__MODULE__{columns: cols, pending_inserts: inserts} = grid) do
    blank_row = List.duplicate(nil, max(1, length(cols)))
    new_r_idx = length(grid.rows) + length(inserts)

    %{
      grid
      | pending_inserts: inserts ++ [blank_row],
        total_rows: length(grid.rows) + length(inserts) + 1,
        mode: :selecting,
        selected_cell: {new_r_idx, 0}
    }
  end

  @doc """
  Toggles deletion mark on `r_idx` (or discards an unsaved inserted row).
  """
  @spec toggle_delete_row(t(), non_neg_integer()) :: t()
  def toggle_delete_row(%__MODULE__{} = grid, r_idx) do
    base_len = length(grid.rows)

    if r_idx >= base_len do
      ins_idx = r_idx - base_len
      updated_inserts = List.delete_at(grid.pending_inserts, ins_idx)
      new_total = base_len + length(updated_inserts)
      new_r = min(max(0, new_total - 1), r_idx)

      %{
        grid
        | pending_inserts: updated_inserts,
          total_rows: new_total,
          selected_cell: {new_r, elem(grid.selected_cell, 1)}
      }
    else
      deletes =
        if MapSet.member?(grid.pending_deletes, r_idx) do
          MapSet.delete(grid.pending_deletes, r_idx)
        else
          MapSet.put(grid.pending_deletes, r_idx)
        end

      %{grid | pending_deletes: deletes}
    end
  end

  @doc """
  Discards all staged edits, inserts, and deletes.
  """
  @spec revert_staged_changes(t()) :: t()
  def revert_staged_changes(%__MODULE__{rows: rows} = grid) do
    %{
      grid
      | pending_edits: %{},
        pending_inserts: [],
        pending_deletes: MapSet.new(),
        editing_cell: nil,
        total_rows: length(rows),
        selected_cell:
          {min(max(0, length(rows) - 1), elem(grid.selected_cell, 0)),
           elem(grid.selected_cell, 1)}
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
        rows_tuple: List.to_tuple(updated_rows),
        cached_static_widths: static_w,
        total_rows: length(updated_rows) + length(grid.pending_inserts),
        has_more: has_more,
        loading_more: false
    }
  end

  @doc """
  Checks if current scroll offset or selection cursor is near the end of loaded rows (default threshold: 25 rows).
  """
  @spec near_bottom?(t(), pos_integer(), non_neg_integer()) :: boolean()
  def near_bottom?(
        %__MODULE__{total_rows: total, rows: rows, scroll_offset: offset, selected_cell: {r, _}},
        viewport_h,
        threshold \\ 25
      ) do
    row_count = if total > 0, do: total, else: length(rows)

    if row_count == 0 do
      false
    else
      max_top = max(0, row_count - max(1, viewport_h))
      offset >= max(0, max_top - threshold) or r >= max(0, row_count - 1 - threshold)
    end
  end

  @doc """
  Returns the slice of rows currently visible in the viewport from `scroll_offset`.
  """
  @spec visible_rows(t(), pos_integer()) :: [list()]
  def visible_rows(%__MODULE__{rows: rows, scroll_offset: offset}, viewport_h \\ 20) do
    rows
    |> Enum.drop(max(0, offset || 0))
    |> Enum.take(max(1, viewport_h))
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

    all_w = static_widths(grid)
    max_col_off = max_col_offset(all_w, max_width)

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
            current_widths = column_widths(all_w, max_width, curr_col_scroll)
            current_last_visible = curr_col_scroll + length(current_widths) - 1

            ns =
              if curr_col_scroll >= max_col_off do
                curr_col_scroll
              else
                Enum.reduce_while(
                  (curr_col_scroll + 1)..max_col_off,
                  curr_col_scroll + 1,
                  fn test_off, _acc ->
                    test_widths = column_widths(all_w, max_width, test_off)
                    test_last = test_off + length(test_widths) - 1

                    if test_last > current_last_visible do
                      {:halt, test_off}
                    else
                      {:cont, test_off + 1}
                    end
                  end
                )
                |> min(max_col_off)
              end

            nc = min(max(0, col_count - 1), c + 1)
            {ns, nc}
          else
            nc = min(max(0, col_count - 1), c + 1)
            widths = column_widths(all_w, max_width, curr_col_scroll)
            visible_count = length(widths)

            ns =
              if nc >= curr_col_scroll + visible_count do
                if curr_col_scroll >= max_col_off do
                  curr_col_scroll
                else
                  Enum.reduce_while((curr_col_scroll + 1)..max_col_off, max_col_off, fn test_off,
                                                                                        _acc ->
                    test_widths = column_widths(all_w, max_width, test_off)
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
  Scrolls the DataGrid viewport directly (for mouse wheel / trackpad scrolling),
  ensuring the table scrolls immediately in both `:browsing` and `:selecting` modes.
  In `:selecting` mode, `selected_cell` stays clamped within the visible viewport.
  """
  @spec scroll_viewport(t(), atom(), pos_integer(), keyword()) :: t()
  def scroll_viewport(%__MODULE__{} = grid, direction, viewport_h \\ 20, opts \\ []) do
    max_width = Keyword.get(opts, :max_width, 999_999)
    step = Keyword.get(opts, :step, 3)
    row_count = if grid.total_rows > 0, do: grid.total_rows, else: length(grid.rows)
    col_count = length(grid.columns)

    max_top = max(0, row_count - max(1, viewport_h))
    max_row = max(0, row_count - 1)
    {r, c} = grid.selected_cell
    curr_scroll = grid.scroll_offset || 0
    curr_col_scroll = grid.col_offset || 0

    all_w = static_widths(grid)
    max_col_off = max_col_offset(all_w, max_width)

    {new_scroll, new_r} =
      case direction do
        :up ->
          ns = max(0, curr_scroll - step)

          nr =
            if grid.mode == :selecting do
              min(max_row, min(ns + viewport_h - 1, max(ns, r)))
            else
              max(0, r - step)
            end

          {ns, nr}

        :down ->
          ns = min(max_top, curr_scroll + step)

          nr =
            if grid.mode == :selecting do
              max(ns, min(max_row, r))
            else
              min(max_row, r + step)
            end

          {ns, nr}

        _ ->
          {curr_scroll, r}
      end

    {new_col_scroll, new_c} =
      case direction do
        :left ->
          ns = max(0, curr_col_scroll - 1)
          vis_count = length(column_widths(all_w, max_width, ns))

          nc =
            if grid.mode == :selecting do
              max(ns, min(ns + max(0, vis_count - 1), c))
            else
              max(0, c - 1)
            end

          {ns, nc}

        :right ->
          ns = min(max_col_off, curr_col_scroll + 1)
          vis_count = length(column_widths(all_w, max_width, ns))

          nc =
            if grid.mode == :selecting do
              max(ns, min(max(0, col_count - 1), min(ns + max(0, vis_count - 1), c)))
            else
              min(max(0, col_count - 1), c + 1)
            end

          {ns, nc}

        _ ->
          {curr_col_scroll, c}
      end

    %{grid | selected_cell: {new_r, new_c}, scroll_offset: new_scroll, col_offset: new_col_scroll}
  end

  @doc """
  Handles key events for DataGrid depending on mode (:browsing vs :selecting).
  Accepts optional `opts` keyword list (e.g. `viewport_h: 30`).
  """
  def handle_key(app, grid, key, opts \\ [])

  def handle_key(app, %__MODULE__{mode: :browsing} = grid, key, opts) do
    vh = Keyword.get(opts, :viewport_h, 20)

    case key do
      k when k in ["v", "V", :enter, :space] ->
        updated_grid = %{grid | mode: :selecting}

        app =
          Map.put(
            app,
            :status_message,
            "SELECT MODE: ↑/↓/←/→ move · [e] edit · [i] insert · [d] delete · [c] copy · [Esc] exit"
          )

        {app, updated_grid}

      k when k in ["s", "S", :f3] ->
        new_app = Strata.UI.App.toggle_structure_view(app)
        {new_app, new_app.datagrid_state || grid}

      k when k in ["o", "O"] ->
        new_app = Strata.UI.App.open_sort_picker(app)
        {new_app, new_app.datagrid_state || grid}

      "-" ->
        handle_clear_sort_key(app, grid)

      "e" ->
        handle_edit_cell_key(app, grid)

      "i" ->
        updated_grid =
          if grid.view_mode == :data do
            insert_blank_row(grid)
          else
            grid
          end

        {app, updated_grid}

      k when k in ["d", :delete] ->
        handle_delete_row_key(app, grid)

      {:ctrl, "z"} ->
        {app, revert_staged_changes(grid)}

      {:ctrl, "s"} ->
        new_app = Strata.UI.App.commit_staged_changes(app)
        {new_app, new_app.datagrid_state || grid}

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

      k when k in ["g"] ->
        {app, move_selection(grid, :home, vh, opts)}

      "G" ->
        {app, move_selection(grid, :end, vh, opts)}

      "F" ->
        new_app = Strata.UI.App.filter_by_selected_cell(app)
        {new_app, new_app.datagrid_state || grid}

      k when k in ["f", "/", {:ctrl, "f"}] ->
        mode_opts = if k == "/", do: [all_columns: true], else: []
        new_app = Strata.UI.App.open_filter_bar(app, mode_opts)
        {new_app, new_app.datagrid_state || grid}

      {:ctrl, "l"} ->
        new_app = Strata.UI.App.clear_table_filter(app)
        {new_app, new_app.datagrid_state || grid}

      k when k in ["I", :f4] ->
        new_app = Strata.UI.App.toggle_inspector(app)
        {new_app, new_app.datagrid_state || grid}

      k when k in ["[", "]", "{", "}"] ->
        {handle_inspector_scroll_key(app, k), grid}

      "m" ->
        if Map.get(app, :inspector_open, false) do
          {Strata.UI.App.cycle_inspector_format(app), grid}
        else
          {app, grid}
        end

      :esc ->
        new_app = Strata.UI.App.dismiss_grid_overlays(app)
        {new_app, new_app.datagrid_state || grid}

      k when k in ["E", {:ctrl, "e"}] ->
        app = Strata.UI.App.push_modal(app, Strata.UI.Components.ExportModal.new())
        {app, grid}

      k when k in ["r", "R", :f5] ->
        new_app = Strata.UI.App.refresh_active_table(app)
        {new_app, new_app.datagrid_state || grid}

      k when k in ["c", "C", "y", {:ctrl, "c"}] ->
        copy_selected_cell(app, grid)

      "Y" ->
        copy_selected_row(app, grid)

      _ ->
        {app, grid}
    end
  end

  def handle_key(app, %__MODULE__{mode: :selecting} = grid, key, opts) do
    vh = Keyword.get(opts, :viewport_h, 20)

    case key do
      :esc ->
        if Map.get(app, :inspector_open, false) do
          {%{
             app
             | inspector_open: false,
               status_message: "Inspector closed — press [Esc] again to exit Select"
           }, grid}
        else
          exit_selecting_mode(app, grid)
        end

      k when k in ["v", "V"] ->
        exit_selecting_mode(app, grid)

      k when k in ["s", "S", :f3] ->
        new_app = Strata.UI.App.toggle_structure_view(app)
        {new_app, new_app.datagrid_state || grid}

      k when k in ["o", "O"] ->
        {_r, c} = grid.selected_cell
        new_app = Strata.UI.App.sort_active_table_by_col(app, c)
        {new_app, new_app.datagrid_state || grid}

      "-" ->
        handle_clear_sort_key(app, grid)

      "e" ->
        handle_edit_cell_key(app, grid)

      "i" ->
        if grid.view_mode == :data and grid.columns != [] do
          {app, insert_blank_row(grid)}
        else
          {app, grid}
        end

      k when k in ["d", :delete] ->
        handle_delete_row_key(app, grid)

      {:ctrl, "z"} ->
        {app, revert_staged_changes(grid)}

      {:ctrl, "s"} ->
        new_app = Strata.UI.App.commit_staged_changes(app)
        {new_app, new_app.datagrid_state || grid}

      k when k in ["c", "C", "y", {:ctrl, "c"}] ->
        copy_selected_cell(app, grid)

      "Y" ->
        copy_selected_row(app, grid)

      k when k in [:enter, :space] ->
        new_app = Strata.UI.App.open_inspector(app)
        {new_app, new_app.datagrid_state || grid}

      k when k in ["I", :f4] ->
        new_app = Strata.UI.App.toggle_inspector(app)
        {new_app, new_app.datagrid_state || grid}

      k when k in ["[", "]", "{", "}"] ->
        {handle_inspector_scroll_key(app, k), grid}

      "m" ->
        if Map.get(app, :inspector_open, false) do
          {Strata.UI.App.cycle_inspector_format(app), grid}
        else
          {app, grid}
        end

      {:ctrl, "l"} ->
        new_app = Strata.UI.App.clear_table_filter(app)
        {new_app, new_app.datagrid_state || grid}

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

      "g" ->
        {app, move_selection(grid, :home, vh, opts)}

      "G" ->
        {app, move_selection(grid, :end, vh, opts)}

      "F" ->
        new_app = Strata.UI.App.filter_by_selected_cell(app)
        {new_app, new_app.datagrid_state || grid}

      k when k in ["f", "/", {:ctrl, "f"}] ->
        mode_opts = if k == "/", do: [all_columns: true], else: []
        new_app = Strata.UI.App.open_filter_bar(app, mode_opts)
        {new_app, new_app.datagrid_state || grid}

      k when k in ["E", {:ctrl, "e"}] ->
        app = Strata.UI.App.push_modal(app, Strata.UI.Components.ExportModal.new())
        {app, grid}

      k when k in ["r", "R", :f5] ->
        new_app = Strata.UI.App.refresh_active_table(app)
        {new_app, new_app.datagrid_state || grid}

      _ ->
        {app, grid}
    end
  end

  def handle_key(app, grid, _key, _opts), do: {app, grid}

  defp handle_edit_cell_key(app, %__MODULE__{view_mode: :data, columns: cols} = grid)
       when cols != [] do
    new_app = Strata.UI.App.start_inline_edit(app)
    {new_app, new_app.datagrid_state || grid}
  end

  defp handle_edit_cell_key(app, grid), do: {app, grid}

  defp handle_delete_row_key(app, %__MODULE__{view_mode: :data} = grid) do
    if effective_rows(grid) != [] do
      {r, _c} = grid.selected_cell
      {app, toggle_delete_row(grid, r)}
    else
      {app, grid}
    end
  end

  defp handle_delete_row_key(app, grid), do: {app, grid}

  defp handle_clear_sort_key(app, %__MODULE__{sort_by: nil} = grid), do: {app, grid}

  defp handle_clear_sort_key(app, grid) do
    new_app = Strata.UI.App.clear_active_sort(app)
    {new_app, new_app.datagrid_state || grid}
  end

  defp handle_inspector_scroll_key(%{inspector_open: true} = app, key) do
    case key do
      "[" -> Strata.UI.App.scroll_inspector(app, :value, -2)
      "]" -> Strata.UI.App.scroll_inspector(app, :value, 2)
      "{" -> Strata.UI.App.scroll_inspector(app, :summary, -2)
      "}" -> Strata.UI.App.scroll_inspector(app, :summary, 2)
      _ -> app
    end
  end

  defp handle_inspector_scroll_key(app, _key), do: app

  defp exit_selecting_mode(app, grid) do
    app =
      Map.put(
        app,
        :status_message,
        "BROWSING MODE: Press [v] or click cell for Select Mode · [?] Actions"
      )

    {app, %{grid | mode: :browsing}}
  end

  defp copy_selected_cell(app, grid) do
    eff = effective_rows(grid)

    if eff == [] do
      {Map.put(app, :status_message, "📋 No data to copy"), grid}
    else
      {r, c} = grid.selected_cell
      raw_cell = eff |> Enum.at(r, []) |> Enum.at(c, nil)
      col_name = Enum.at(grid.columns, c, "Cell")
      copy_str = format_cell_for_copy(raw_cell)
      preview_str = Strata.Formatter.sanitize_cell(raw_cell)

      status =
        case Strata.Clipboard.copy(copy_str) do
          :ok ->
            preview =
              if String.length(preview_str) > 36,
                do: String.slice(preview_str, 0, 33) <> "...",
                else: preview_str

            "📋 Copied #{col_name}: #{preview}"

          {:error, _reason} ->
            "📋 Copy failed (no OS clipboard tool) — press Enter to inspect"
        end

      {Map.put(app, :status_message, status), grid}
    end
  end

  defp copy_selected_row(app, grid) do
    eff = effective_rows(grid)

    if eff == [] do
      {Map.put(app, :status_message, "📋 No row to copy"), grid}
    else
      {r, _c} = grid.selected_cell
      row_vals = eff |> Enum.at(r, [])
      row_str = Enum.map_join(row_vals, "\t", &format_cell_for_copy/1)

      status =
        case Strata.Clipboard.copy(row_str) do
          :ok -> "📋 Copied row #{r + 1} (#{length(row_vals)} cols) to clipboard"
          {:error, _reason} -> "📋 Copy row failed (no OS clipboard tool)"
        end

      {Map.put(app, :status_message, status), grid}
    end
  end

  @doc """
  Formats a grid cell value for clipboard copy, preserving valid newlines while
  sanitizing binary/non-printable data.
  """
  def format_cell_for_copy(val) when is_binary(val) do
    if String.printable?(val), do: val, else: Strata.Formatter.sanitize_cell(val)
  end

  def format_cell_for_copy(val), do: Strata.Formatter.sanitize_cell(val)

  @doc """
  Computes or returns cached static width for every column.
  """
  def static_widths(%__MODULE__{cached_static_widths: widths})
      when is_list(widths) and widths != [] do
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
  def max_col_offset(all_w, max_width)
      when is_list(all_w) and (all_w == [] or is_integer(hd(all_w))) do
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
  def column_widths(all_w, max_width, col_offset)
      when is_list(all_w) and (all_w == [] or is_integer(hd(all_w))) do
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
end
