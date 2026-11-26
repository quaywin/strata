defmodule Strata.UI.Selection do
  @moduledoc """
  Handles drag-to-select text highlighting and automatic clipboard copy across
  TUI panes (`Inspector`, `SQL Editor`, `DataGrid`, `Sidebar`, and `Modals`)
  without requiring the user to hold `Shift`.
  """

  alias ExRatatui.Style
  alias ExRatatui.Text.{Line, Span}
  alias ExRatatui.Widgets.Paragraph
  alias Strata.UI.Renderer

  @type point :: {non_neg_integer(), non_neg_integer()}
  @type bounds :: %{
          min_x: non_neg_integer(),
          max_x: non_neg_integer(),
          min_y: non_neg_integer(),
          max_y: non_neg_integer()
        }

  @doc """
  Captures a fast in-memory character grid of the currently rendered `app` screen
  using `ExRatatui.CellSession`, with any active selection overlay excluded.
  """
  @spec capture_screen(map()) :: map()
  def capture_screen(app) do
    {w, h} = Map.get(app, :window_size, {120, 40})
    w = max(1, w)
    h = max(1, h)

    clean_app =
      Map.merge(app, %{
        text_selection: nil,
        selection_screen: nil,
        selection_bounds: nil,
        selection_capture?: true
      })

    widgets = Renderer.render(clean_app)

    session = ExRatatui.CellSession.new(w, h)

    try do
      :ok = ExRatatui.CellSession.draw(session, widgets)
      snap = ExRatatui.CellSession.take_cells(session)

      non_ascii_syms =
        for cell <- snap.cells,
            not cell.skip,
            is_binary(cell.symbol),
            byte_size(cell.symbol) > 1 do
          cell.symbol
        end

      ensure_grapheme_widths_cached(non_ascii_syms)

      {rows, _prev_row, _skip_until} =
        Enum.reduce(snap.cells, {%{}, -1, -1}, fn cell, {acc, prev_row, skip_until} ->
          skip_until = if cell.row != prev_row, do: -1, else: skip_until

          {sym, next_skip_until} =
            if cell.skip or cell.col < skip_until do
              {"", skip_until}
            else
              s = cell.symbol || " "
              dw = grapheme_width(s)
              next_su = if dw > 1, do: cell.col + dw, else: skip_until
              {s, next_su}
            end

          row_map = Map.get(acc, cell.row, %{})
          {Map.put(acc, cell.row, Map.put(row_map, cell.col, sym)), cell.row, next_skip_until}
        end)

      %{width: w, height: h, rows: rows}
    after
      _ = ExRatatui.CellSession.close(session)
    end
  end

  @doc """
  Determines the inner content bounds `{min_x, max_x, min_y, max_y}` for a drag
  originating at `{ax, ay}` so multi-line selection stays cleanly inside one pane
  without bleeding across adjacent borders or panes.
  """
  @spec bounds_for_anchor(map(), point()) :: bounds()
  def bounds_for_anchor(app, {ax, ay}) do
    {w, h} = Map.get(app, :window_size, {120, 40})
    full = %{min_x: 0, max_x: max(0, w - 1), min_y: 0, max_y: max(0, h - 1)}

    cond do
      Map.get(app, :modals, []) != [] ->
        modal_area = Renderer.modal_area_for(app, {w, h})
        if inside_rect?(ax, ay, modal_area), do: inner_rect_bounds(modal_area), else: full

      true ->
        layout = Renderer.layout({w, h}, Map.get(app, :active_view, :table_view))
        areas = Renderer.datagrid_areas(layout.datagrid, app)
        insp_areas = Renderer.inspector_areas(areas.inspector_area)
        filter_dd = Renderer.filter_dropdown_data(app, layout.datagrid)
        sort_dd = Renderer.sort_picker_data(app, layout.datagrid)
        editor_comp = if layout.editor.height > 0, do: Renderer.editor_completion_rect(app, layout.editor), else: nil

        {editor_tabs, editor_body} =
          if layout.editor.height > 0 do
            tabs = %{x: layout.editor.x, y: layout.editor.y, width: layout.editor.width, height: 1}
            body = %{x: layout.editor.x, y: layout.editor.y + 1, width: layout.editor.width, height: max(1, layout.editor.height - 1)}
            {tabs, body}
          else
            {nil, nil}
          end

        candidates =
          [
            filter_dd && filter_dd.rect,
            sort_dd && sort_dd.rect,
            editor_comp,
            insp_areas && insp_areas.value_area,
            insp_areas && insp_areas.summary_area,
            areas.filter_area,
            areas.grid_area,
            editor_body,
            editor_tabs,
            layout.sidebar,
            layout.footer
          ]
          |> Enum.reject(&is_nil/1)

        case Enum.find(candidates, &inside_rect?(ax, ay, &1)) do
          nil ->
            full

          rect ->
            b = inner_rect_bounds(rect)
            # In SQL Editor body, if drag starts in code region (past line-number gutter), keep selection inside code
            if rect == editor_body do
              code_min_x = editor_code_min_x(app, editor_body)

              if ax >= code_min_x and code_min_x <= b.max_x do
                %{b | min_x: code_min_x}
              else
                b
              end
            else
              b
            end
        end
    end
  end

  @doc """
  Computes ordered `{row_y, x_from, x_to}` line segments between `anchor` and `current`
  constrained inclusively within `bounds` so highlighted cells match mouse positions 1:1.
  """
  @spec selection_spans(point(), point(), bounds()) :: [{integer(), integer(), integer()}]
  def selection_spans({ax, ay}, {cx, cy}, bounds) do
    {sx, sy} = clamp_point({ax, ay}, bounds)
    {ex, ey} = clamp_point({cx, cy}, bounds)

    {{x0, y0}, {x1, y1}} =
      if sy < ey or (sy == ey and sx <= ex) do
        {{sx, sy}, {ex, ey}}
      else
        {{ex, ey}, {sx, sy}}
      end

    Enum.map(y0..y1, fn y ->
      cond do
        y0 == y1 -> {y, x0, x1}
        y == y0 -> {y, x0, bounds.max_x}
        y == y1 -> {y, bounds.min_x, x1}
        true -> {y, bounds.min_x, bounds.max_x}
      end
    end)
  end

  @doc """
  Extracts clean text from the captured `screen` across the dragged selection range.
  """
  @spec extract_text(map(), point(), point(), bounds()) :: String.t()
  def extract_text(%{rows: rows} = _screen, anchor, current, bounds) do
    selection_spans(anchor, current, bounds)
    |> Enum.map(fn {y, x_from, x_to} ->
      row_map = Map.get(rows, y, %{})
      {_adj_from, _adj_to, text} = read_span_text(row_map, x_from, x_to, bounds.min_x, bounds.max_x, overlay?: false)
      String.trim_trailing(text)
    end)
    |> trim_empty_edge_lines()
    |> Enum.join("\n")
  end

  @doc """
  Builds highlighted overlay Paragraph widgets showing the currently selected text range.
  """
  @spec render_overlays(map(), point(), point(), bounds()) :: [{Paragraph.t(), ExRatatui.Layout.Rect.t()}]
  def render_overlays(%{rows: rows} = _screen, anchor, current, bounds) do
    hl_style = %Style{fg: :black, bg: :cyan, modifiers: [:bold]}

    selection_spans(anchor, current, bounds)
    |> Enum.map(fn {y, x_from, x_to} ->
      row_map = Map.get(rows, y, %{})
      {adj_from, adj_to, text} = read_span_text(row_map, x_from, x_to, bounds.min_x, bounds.max_x, overlay?: true)
      w = max(1, adj_to - adj_from + 1)

      widget = %Paragraph{
        text: [Line.new([Span.new(text, style: hl_style)])],
        style: hl_style
      }

      rect = %ExRatatui.Layout.Rect{x: adj_from, y: y, width: w, height: 1}
      {widget, rect}
    end)
  end

  defp read_span_text(row_map, x_from, x_to, min_x, max_x, opts) do
    overlay? = Keyword.get(opts, :overlay?, false)
    adj_from = adjust_wide_left(row_map, x_from, min_x)
    adj_to = adjust_wide_right(row_map, x_to, max_x)

    text =
      if overlay? do
        Enum.map_join(adj_from..adj_to, "", fn x ->
          cond do
            x == adj_from and Map.get(row_map, x, " ") == "" -> " "
            x == adj_to and adj_to == max_x and Map.get(row_map, adj_to + 1) == "" -> " "
            true -> Map.get(row_map, x, " ")
          end
        end)
      else
        Enum.map_join(adj_from..adj_to, "", fn x -> Map.get(row_map, x, " ") end)
      end

    {adj_from, adj_to, text}
  end

  defp adjust_wide_left(row_map, x, min_x) when x > min_x do
    if Map.get(row_map, x) == "" and Map.get(row_map, x - 1, "") != "", do: x - 1, else: x
  end

  defp adjust_wide_left(_row_map, x, _min_x), do: x

  defp adjust_wide_right(row_map, x, max_x) when x < max_x do
    if Map.get(row_map, x, " ") != "" and Map.get(row_map, x + 1) == "", do: x + 1, else: x
  end

  defp adjust_wide_right(_row_map, x, _max_x), do: x

  defp ensure_grapheme_widths_cached([]), do: :ok

  defp ensure_grapheme_widths_cached(syms) do
    {curr, old} = Process.get(:selection_grapheme_width, {%{}, %{}})

    uncached =
      syms
      |> Enum.uniq()
      |> Enum.reject(&(Map.has_key?(curr, &1) or Map.has_key?(old, &1)))

    if uncached != [] do
      uncached
      |> Enum.chunk_every(64)
      |> Enum.each(&measure_and_cache_chunk/1)
    end

    :ok
  end

  defp measure_and_cache_chunk(chunk) do
    alias ExRatatui.Layout.Rect
    row_count = length(chunk)
    session = ExRatatui.CellSession.new(8, row_count)

    try do
      lines = Enum.map(chunk, fn sym -> Line.new([Span.new(sym <> "X")]) end)
      :ok = ExRatatui.CellSession.draw(session, [{%Paragraph{text: lines}, %Rect{x: 0, y: 0, width: 8, height: row_count}}])
      snap = ExRatatui.CellSession.take_cells(session)
      by_row = Enum.group_by(snap.cells, & &1.row)

      chunk
      |> Enum.with_index()
      |> Enum.each(fn {sym, row_idx} ->
        dw =
          by_row
          |> Map.get(row_idx, [])
          |> Enum.sort_by(& &1.col)
          |> Enum.find_value(1, fn cell ->
            if cell.symbol == "X", do: cell.col
          end)

        Strata.UI.Cache.fetch(:selection_grapheme_width, sym, 2_000, fn -> dw end)
      end)
    after
      _ = ExRatatui.CellSession.close(session)
    end
  end

  defp grapheme_width(sym) when byte_size(sym) <= 1, do: 1

  defp grapheme_width(sym) do
    Strata.UI.Cache.fetch(:selection_grapheme_width, sym, 2_000, fn -> 1 end)
  end

  defp editor_code_min_x(app, editor_body) do
    active_tab = Enum.find(Map.get(app, :tabs, []), &(&1.id == Map.get(app, :active_tab_id)))
    content = (active_tab && Map.get(active_tab, :content)) || ""
    line_count = content |> String.split("\n") |> length()
    digits = max(3, String.length(Integer.to_string(line_count)))
    editor_body.x + 1 + digits + 3
  end

  defp clamp_point({x, y}, %{min_x: min_x, max_x: max_x, min_y: min_y, max_y: max_y}) do
    {max(min_x, min(max_x, x)), max(min_y, min(max_y, y))}
  end

  defp inner_rect_bounds(%{x: x, y: y, width: w, height: h}) do
    min_x = if w >= 3, do: x + 1, else: x
    max_x = if w >= 3, do: x + w - 2, else: x + max(0, w - 1)
    min_y = if h >= 3, do: y + 1, else: y
    max_y = if h >= 3, do: y + h - 2, else: y + max(0, h - 1)

    %{
      min_x: min_x,
      max_x: max(min_x, max_x),
      min_y: min_y,
      max_y: max(min_y, max_y)
    }
  end

  defp inside_rect?(x, y, %{x: rx, y: ry, width: rw, height: rh}) do
    rw > 0 and rh > 0 and x >= rx and x < rx + rw and y >= ry and y < ry + rh
  end

  defp trim_empty_edge_lines(lines) do
    lines
    |> Enum.drop_while(&(&1 == ""))
    |> Enum.reverse()
    |> Enum.drop_while(&(&1 == ""))
    |> Enum.reverse()
  end
end
