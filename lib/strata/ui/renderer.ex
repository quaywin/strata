defmodule Strata.UI.Renderer do
  @moduledoc """
  Ratatui layout dispatcher and component tree renderer helper.
  Partitions terminal window into grid chunks and dispatches rendering for panes and modals.
  """

  alias Strata.UI.Components.DataGrid
  alias Strata.UI.Components.Footer
  alias Strata.UI.Components.Sidebar
  alias Strata.UI.Components.SQLEditor

  @type rect :: %{x: non_neg_integer(), y: non_neg_integer(), width: pos_integer(), height: pos_integer()}

  @doc """
  Computes layout grid rectangles for main UI panes based on window size {width, height} and active_view.
  """
  @spec layout({pos_integer(), pos_integer()}, :table_view | :query_view) :: map()
  def layout(window_size, active_view \\ :query_view)

  def layout({width, height}, active_view) when is_integer(width) and is_integer(height) do
    footer_height = 1

    content_height = max(1, height - footer_height)

    sidebar_width = max(24, min(40, round(width * 0.25)))
    right_width = max(1, width - sidebar_width)

    {editor_height, datagrid_height, datagrid_y} =
      case active_view do
        :table_view ->
          {0, content_height, 0}

        :query_view ->
          eh = round(content_height * 0.40)
          dh = max(1, content_height - eh)
          {eh, dh, eh}

        _ ->
          eh = round(content_height * 0.40)
          dh = max(1, content_height - eh)
          {eh, dh, eh}
      end

    %{
      header: %{x: 0, y: 0, width: width, height: 0},
      sidebar: %{x: 0, y: 0, width: sidebar_width, height: content_height},
      editor: %{
        x: sidebar_width,
        y: 0,
        width: right_width,
        height: editor_height
      },
      datagrid: %{
        x: sidebar_width,
        y: datagrid_y,
        width: right_width,
        height: datagrid_height
      },
      footer: %{
        x: 0,
        y: height - footer_height,
        width: width,
        height: footer_height
      }
    }
  end

  @doc """
  Computes centered rect area for overlay modals given window size and desired modal dimensions.
  """
  @spec modal_layout({pos_integer(), pos_integer()}, {pos_integer(), pos_integer()}) :: rect()
  def modal_layout({ww, wh}, {mw, mh}) do
    width = min(ww, mw)
    height = min(wh, mh)
    x = max(0, div(ww - width, 2))
    y = max(0, div(wh - height, 2))

    %{x: x, y: y, width: width, height: height}
  end

  @doc """
  Renders the complete UI component tree for current app state.
  """
  def render(app) do
    areas = layout(app.window_size, Map.get(app, :active_view, :query_view))

    header_item = render_header(app, areas.header)
    sidebar_item = render_sidebar(app, areas.sidebar)
    editor_item = render_editor(app, areas.editor)
    datagrid_item = render_datagrid(app, areas.datagrid)
    footer_item = render_footer(app, areas.footer)

    modal_items = render_modal(app, app.window_size)

    selection_items =
      case {Map.get(app, :text_selection), Map.get(app, :selection_screen), Map.get(app, :selection_bounds)} do
        {{anchor, current}, %{} = screen, %{} = bounds} ->
          Strata.UI.Selection.render_overlays(screen, anchor, current, bounds)

        _ ->
          []
      end

    List.flatten([header_item, sidebar_item, editor_item, datagrid_item, footer_item] ++ modal_items ++ selection_items)
  end

  defp to_rect(%{x: x, y: y, width: w, height: h}) do
    %ExRatatui.Layout.Rect{x: x, y: y, width: w, height: h}
  end

  defp render_header(app, area) do
    if area.height > 0 do
      table_option = if Map.get(app, :active_view) == :table_view, do: "[★ 1: Table View]", else: "[ 1: Table View ]"
      query_option = if Map.get(app, :active_view) == :query_view, do: "[★ 2: Query View]", else: "[ 2: Query View ]"

      header_text = " 🗄️ Strata TUI  │  View: #{table_option} #{query_option}"

      widget = %ExRatatui.Widgets.Paragraph{
        text: header_text,
        style: %ExRatatui.Style{fg: :white, bg: :blue}
      }

      {widget, to_rect(area)}
    else
      widget = %ExRatatui.Widgets.Paragraph{text: ""}
      {widget, to_rect(area)}
    end
  end

  defp render_sidebar(app, area) do
    sidebar_vp = Sidebar.render_viewport(app, area)
    fg = if app.focus == :sidebar, do: :yellow, else: :cyan

    viewport_h = sidebar_vp.viewport_h
    max_offset = sidebar_vp.max_offset
    clamped_offset = sidebar_vp.clamped_offset

    # Adjust selected index relative to the visible slice
    global_selected = sidebar_vp.selected_index

    local_selected =
      if global_selected >= clamped_offset and global_selected < clamped_offset + viewport_h do
        global_selected - clamped_offset
      else
        nil
      end

    sliced_list_items = sidebar_vp.styled_items

    hl_style =
      if app.focus == :sidebar do
        %ExRatatui.Style{fg: :black, bg: :yellow, modifiers: [:bold]}
      else
        %ExRatatui.Style{fg: :yellow, modifiers: [:bold]}
      end

    list_widget = %ExRatatui.Widgets.List{
      items: sliced_list_items,
      selected: local_selected,
      highlight_symbol: "▸ ",
      highlight_style: hl_style,
      scroll_padding: 0,
      block: %ExRatatui.Widgets.Block{
        title: " #{sidebar_vp.title} ",
        borders: [:all],
        border_type: :rounded,
        border_style: %ExRatatui.Style{fg: fg}
      }
    }

    scrollbar_widget = %ExRatatui.Widgets.Scrollbar{
      orientation: :vertical_right,
      content_length: max(1, max_offset),
      position: clamped_offset,
      thumb_symbol: "┃",
      track_symbol: "│",
      thumb_style: %ExRatatui.Style{fg: :yellow},
      track_style: %ExRatatui.Style{fg: :dark_gray}
    }

    rect = to_rect(area)
    [{list_widget, rect}, {scrollbar_widget, rect}]
  end

  defp render_editor(app, area) do
    if area.height > 0 do
      editor_chunk = SQLEditor.render(app, area)
      fg = if app.focus == :editor, do: :yellow, else: :cyan

      tab_height = 1
      body_height = max(1, area.height - tab_height)

      tabs_rect = %ExRatatui.Layout.Rect{
        x: area.x,
        y: area.y,
        width: area.width,
        height: tab_height
      }

      body_rect = %ExRatatui.Layout.Rect{
        x: area.x,
        y: area.y + tab_height,
        width: area.width,
        height: body_height
      }

      titles = Map.get(editor_chunk, :tab_titles, ["Query 1"])
      selected_idx = Map.get(editor_chunk, :active_index, 0)

      tabs_widget = %ExRatatui.Widgets.Tabs{
        titles: if(titles != [], do: titles, else: ["Query 1"]),
        selected: selected_idx,
        style: %ExRatatui.Style{fg: :white},
        highlight_style: %ExRatatui.Style{fg: :black, bg: :yellow, modifiers: [:bold]},
        divider: "│"
      }

      {c_row, _c_col} = Map.get(editor_chunk, :cursor, {0, 0})
      viewport_h = max(1, body_height - 2)
      scroll_top = max(0, c_row - viewport_h + 1)

      visible_lines =
        editor_chunk.lines
        |> Enum.drop(scroll_top)
        |> Enum.take(viewport_h)

      editor_focused? = app.focus == :editor and not Map.get(app, :selection_capture?, false)
      styled_lines = Enum.map(visible_lines, &build_highlighted_sql_line(&1, editor_focused?))

      editor_title =
        case Sidebar.resolve_selection_context(app) do
          {%{name: conn_name} = prof, schema} when is_binary(conn_name) and conn_name != "" ->
            raw_db = to_string(Map.get(prof, :database) || "") |> String.trim()

            db_name =
              cond do
                raw_db in ["", ":memory:"] -> ""
                Map.get(prof, :driver) == :sqlite -> Path.basename(raw_db)
                true -> raw_db
              end

            db_part =
              if db_name != "" and String.downcase(db_name) != String.downcase(conn_name) and db_name != schema,
                do: " · #{db_name}",
                else: ""

            schema_part = if is_binary(schema) and schema != "", do: " · #{schema}", else: ""
            " SQL EDITOR [#{conn_name}#{db_part}#{schema_part}] "

          _ ->
            " SQL EDITOR "
        end

      paragraph_widget = %ExRatatui.Widgets.Paragraph{
        text: styled_lines,
        block: %ExRatatui.Widgets.Block{
          title: editor_title,
          borders: [:all],
          border_type: :rounded,
          border_style: %ExRatatui.Style{fg: fg}
        }
      }

      comp = Map.get(editor_chunk, :completion, %{})

      completion_items =
        case editor_completion_rect(app, area) do
          %{} = comp_rect ->
            suggs = Map.get(comp, :suggestions, [])
            sel_idx = Map.get(comp, :selected_index) || 0
            popup_rect = to_rect(comp_rect)

            items =
              Enum.map(suggs, fn sug ->
                icon =
                  case sug.type do
                    :keyword -> "🔤"
                    :table -> "📋"
                    :column -> "🔹"
                    _ -> "•"
                  end

                " #{icon} #{sug.label}"
              end)

            clear_w = %ExRatatui.Widgets.Clear{}

            list_w = %ExRatatui.Widgets.List{
              items: items,
              selected: sel_idx,
              highlight_symbol: "> ",
              highlight_style: %ExRatatui.Style{fg: :black, bg: :yellow, modifiers: [:bold]},
              block: %ExRatatui.Widgets.Block{
                title: " SUGGESTIONS ",
                borders: [:all],
                border_type: :rounded,
                border_style: %ExRatatui.Style{fg: :yellow}
              }
            }

            [{clear_w, popup_rect}, {list_w, popup_rect}]

          nil ->
            []
        end

      [{tabs_widget, tabs_rect}, {paragraph_widget, body_rect}] ++ completion_items
    else
      widget = %ExRatatui.Widgets.Paragraph{text: ""}
      {widget, to_rect(area)}
    end
  end

  @doc """
  Computes the floating SQL Editor autocomplete popup rect when active, or `nil` when hidden.
  Shared between `render_editor/2` and `Strata.UI.Selection.bounds_for_anchor/2`.
  """
  @spec editor_completion_rect(map(), rect()) :: rect() | nil
  def editor_completion_rect(app, %{height: h} = area) when h > 0 do
    active_tab = Enum.find(Map.get(app, :tabs, []), &(&1.id == Map.get(app, :active_tab_id)))
    comp = Map.get(active_tab || %{}, :completion, %{})
    suggs = Map.get(comp, :suggestions, [])

    if comp != %{} and Map.get(comp, :active?, false) and suggs != [] do
      {c_row, c_col} = Map.get(active_tab, :cursor, {0, 0})
      body_height = max(1, area.height - 1)
      viewport_h = max(1, body_height - 2)
      scroll_top = max(0, c_row - viewport_h + 1)

      popup_width = 24
      popup_height = min(7, length(suggs) + 2)

      px = min(area.x + area.width - popup_width, area.x + c_col + 6)
      py = min(area.y + area.height - popup_height, area.y + max(0, c_row - scroll_top) + 2)

      %{
        x: max(area.x, px),
        y: max(area.y, py),
        width: popup_width,
        height: popup_height
      }
    else
      nil
    end
  end

  def editor_completion_rect(_app, _area), do: nil

  defp build_highlighted_sql_line(line_info, editor_focused?) do
    alias ExRatatui.Style
    alias ExRatatui.Text.{Line, Span}

    prefix_span = Span.new(line_info.prefix, style: %Style{fg: :dark_gray})

    token_spans =
      case Map.get(line_info, :tokens, []) do
        [] ->
          [Span.new(line_info.text)]

        tokens ->
          Enum.map(tokens, fn %{type: type, text: text} ->
            style =
              case type do
                :keyword -> %Style{fg: :cyan, modifiers: [:bold]}
                :string -> %Style{fg: :green}
                :number -> %Style{fg: :magenta}
                :comment -> %Style{fg: :dark_gray}
                :operator -> %Style{fg: :yellow}
                _ -> %Style{}
              end

            Span.new(text, style: style)
          end)
      end

    spans_with_cursor =
      if editor_focused? and Map.get(line_info, :has_cursor?, false) do
        cursor_col = Map.get(line_info, :cursor_col) || 0
        apply_cursor_to_spans(token_spans, cursor_col)
      else
        token_spans
      end

    Line.new([prefix_span | spans_with_cursor])
  end

  defp apply_cursor_to_spans(spans, cursor_col) do
    alias ExRatatui.Style
    alias ExRatatui.Text.Span

    cursor_style = %Style{fg: :black, bg: :yellow, modifiers: [:bold]}
    total_len = Enum.reduce(spans, 0, fn s, acc -> acc + String.length(s.content) end)

    if cursor_col >= total_len do
      spans ++ [Span.new("█", style: %Style{fg: :yellow})]
    else
      {acc_spans, _pos} =
        Enum.reduce(spans, {[], 0}, fn span, {acc, pos} ->
          len = String.length(span.content)
          span_end = pos + len

          if cursor_col >= pos and cursor_col < span_end do
            local_idx = cursor_col - pos
            before = String.slice(span.content, 0, local_idx)
            char = String.slice(span.content, local_idx, 1)
            after_str = String.slice(span.content, (local_idx + 1)..-1//1)

            parts =
              [
                if(before != "", do: Span.new(before, style: span.style)),
                Span.new(char, style: cursor_style),
                if(after_str != "", do: Span.new(after_str, style: span.style))
              ]
              |> Enum.reject(&is_nil/1)

            {acc ++ parts, span_end}
          else
            {acc ++ [span], span_end}
          end
        end)

      acc_spans
    end
  end

  @doc """
  Partitions `datagrid` area into `{filter_area, grid_area, inspector_area}` based on
  whether the inline filter bar and right inspector drawer are currently open.
  """
  @spec datagrid_areas(rect(), map()) :: %{
          filter_area: rect() | nil,
          grid_area: rect(),
          inspector_area: rect() | nil
        }
  def datagrid_areas(area, app) do
    filter_open? = Map.get(app, :filter_bar_open, false) and area.height >= 7

    {filter_area, body_area} =
      if filter_open? do
        f = %{x: area.x, y: area.y, width: area.width, height: 3}
        b = %{x: area.x, y: area.y + 3, width: area.width, height: max(1, area.height - 3)}
        {f, b}
      else
        {nil, area}
      end

    inspector_open? = Map.get(app, :inspector_open, false) and body_area.width >= 56

    {grid_area, inspector_area} =
      if inspector_open? do
        insp_w = min(44, max(28, round(body_area.width * 0.34)))
        g = %{body_area | width: max(10, body_area.width - insp_w)}
        i = %{x: body_area.x + body_area.width - insp_w, y: body_area.y, width: insp_w, height: body_area.height}
        {g, i}
      else
        {body_area, nil}
      end

    %{filter_area: filter_area, grid_area: grid_area, inspector_area: inspector_area}
  end

  @doc """
  Splits `inspector_area` into two fixed panels: top `value_area` (Data Field) and
  bottom `summary_area` (Row Summary).
  """
  @spec inspector_areas(rect() | nil) :: %{value_area: rect(), summary_area: rect() | nil} | nil
  def inspector_areas(nil), do: nil

  def inspector_areas(%{x: x, y: y, width: w, height: h}) do
    if h >= 8 do
      value_h = max(4, min(h - 4, round(h * 0.54)))
      summary_h = h - value_h

      %{
        value_area: %{x: x, y: y, width: w, height: value_h},
        summary_area: %{x: x, y: y + value_h, width: w, height: summary_h}
      }
    else
      %{
        value_area: %{x: x, y: y, width: w, height: h},
        summary_area: nil
      }
    end
  end

  @doc """
  Computes `{value_lines, summary_lines}` and scroll bounds for the Inspector Drawer.
  Shared between rendering and mouse/key scroll clamping.
  """
  def inspector_data(app, grid, i_area) do
    {r_idx, _c_idx} = grid.selected_cell
    row_vals = DataGrid.effective_row_at(grid, r_idx) || []
    total_rows = max(1, DataGrid.effective_row_count(grid))
    build_inspector_data(app, grid, row_vals, total_rows, i_area)
  end

  def inspector_data(app, grid, all_rows, i_area) when is_list(all_rows) do
    {r_idx, _c_idx} = grid.selected_cell
    row_vals = Enum.at(all_rows, r_idx, [])
    total_rows = max(1, length(all_rows))
    build_inspector_data(app, grid, row_vals, total_rows, i_area)
  end

  defp build_inspector_data(app, grid, row_vals, total_rows, i_area) do
    areas = inspector_areas(i_area)
    {r_idx, c_idx} = grid.selected_cell
    raw_cell = Enum.at(row_vals, c_idx, nil)
    col_name = Enum.at(grid.columns, c_idx, "Cell")
    max_line_w = max(8, i_area.width - 3)
    fmt = Map.get(app, :inspector_format, :auto)

    {value_lines, fmt_badge} = cached_inspector_value_lines(raw_cell, col_name, r_idx, fmt, max_line_w)
    summary_lines = cached_inspector_summary_lines(grid.columns, row_vals, c_idx, max_line_w)

    val_vp = max(1, areas.value_area.height - 2)
    sum_vp = if areas.summary_area, do: max(1, areas.summary_area.height - 2), else: 1

    %{
      areas: areas,
      col_name: col_name,
      fmt_badge: fmt_badge,
      row_idx: r_idx,
      total_rows: total_rows,
      col_idx: c_idx,
      total_cols: max(1, length(grid.columns)),
      value_lines: value_lines,
      summary_lines: summary_lines,
      max_value_scroll: max(0, length(value_lines) - val_vp),
      max_summary_scroll: max(0, length(summary_lines) - sum_vp),
      val_viewport_h: val_vp,
      sum_viewport_h: sum_vp
    }
  end

  defp cached_inspector_summary_lines(columns, row_vals, c_idx, max_line_w) do
    alias ExRatatui.Style
    alias ExRatatui.Text.{Line, Span}

    Strata.UI.Cache.fetch(:strata_inspector_sum_cache, {columns, row_vals, c_idx, max_line_w}, 64, fn ->
      if columns != [] and row_vals != [] do
        columns
        |> Enum.zip(row_vals)
        |> Enum.with_index()
        |> Enum.map(fn {{c, v}, idx} ->
          active? = idx == c_idx
          prefix = if active?, do: "▸ ", else: "  "
          col_str = "#{c}: "
          avail_val = max(4, max_line_w - String.length(prefix) - String.length(col_str))
          val_str = Strata.Formatter.sanitize_cell_preview(v, avail_val)
          clipped_val = if String.length(val_str) > avail_val, do: String.slice(val_str, 0, avail_val - 1) <> "…", else: val_str

          val_style =
            cond do
              active? -> %Style{fg: :yellow, modifiers: [:bold]}
              is_nil(v) -> %Style{fg: :dark_gray}
              is_number(v) -> %Style{fg: :magenta}
              true -> %Style{fg: :white}
            end

          col_style = if active?, do: %Style{fg: :yellow, modifiers: [:bold]}, else: %Style{fg: :cyan}

          Line.new([
            Span.new(prefix, style: col_style),
            Span.new(col_str, style: col_style),
            Span.new(clipped_val, style: val_style)
          ])
        end)
      else
        [Line.new([Span.new("(No row selected)", style: %Style{fg: :dark_gray})])]
      end
    end)
  end

  defp cached_inspector_value_lines(raw_cell, col_name, r_idx, fmt, max_line_w) do
    Strata.UI.Cache.fetch(:strata_inspector_val_cache, {raw_cell, fmt, max_line_w}, 64, fn ->
      compute_inspector_value_lines(raw_cell, col_name, r_idx, fmt, max_line_w)
    end)
  end

  defp compute_inspector_value_lines(raw_cell, col_name, r_idx, fmt, max_line_w) do
    alias ExRatatui.Style
    alias ExRatatui.Text.{Line, Span}

    detail = Strata.UI.Components.CellDetailModal.new(raw_cell, column: col_name, row_index: r_idx + 1)

    cond do
      fmt == :raw ->
        {Strata.Formatter.wrap_text_lines(inspect(raw_cell, pretty: true), max_line_w), "raw"}

      fmt == :text ->
        {Strata.Formatter.wrap_text_lines(Strata.Formatter.format_cell_detail(raw_cell), max_line_w), "text"}

      detail.detected_type == :json ->
        {Strata.Formatter.highlight_json_lines(detail.formatted_value, max_line_w), "JSON"}

      detail.detected_type == :nil ->
        {[Line.new([Span.new("<NULL>", style: %Style{fg: :dark_gray, modifiers: [:bold]})])], "NULL"}

      detail.detected_type == :uuid ->
        {Strata.Formatter.wrap_text_lines(detail.formatted_value, max_line_w, %Style{fg: :cyan}), "UUID"}

      true ->
        {Strata.Formatter.wrap_text_lines(detail.formatted_value, max_line_w, %Style{fg: :white}), to_string(detail.detected_type)}
    end
  end

  defp render_datagrid(app, total_area) do
    %{filter_area: filter_area, grid_area: area, inspector_area: inspector_area} =
      datagrid_areas(total_area, app)

    grid = app.datagrid_state || DataGrid.new()
    base_len = DataGrid.base_row_count(grid)
    total_loaded_rows = DataGrid.effective_row_count(grid)
    {r_idx, c_idx} = grid.selected_cell
    fg = if app.focus == :datagrid, do: :yellow, else: :cyan

    dirty = DataGrid.dirty_count(grid)
    dirty_badge = if dirty > 0, do: " [💾 #{dirty} Pending]", else: ""
    filter_badge = if Map.get(app, :active_filter) != nil, do: " [🔍 FILTERED]", else: ""

    sort_badge =
      case grid.sort_by do
        {col, :asc} -> " [↕ #{col} ▲]"
        {col, :desc} -> " [↕ #{col} ▼]"
        _ -> ""
      end

    mode_badge =
      cond do
        grid.editing_cell != nil -> " [EDITING · Enter stage · Ctrl+N NULL · Esc cancel]"
        grid.view_mode == :structure -> " [STRUCTURE]"
        grid.mode == :selecting -> " [SELECT]"
        true -> " [v:Select]"
      end

    loading_badge = if grid.loading_more, do: " [⏳ Loading...]", else: ""
    total_db_rows = grid.total_db_rows

    row_count_label =
      if is_integer(total_db_rows) and grid.view_mode == :data do
        "#{total_loaded_rows}/#{total_db_rows} rows"
      else
        "#{total_loaded_rows} rows"
      end

    more_status =
      cond do
        grid.view_mode == :structure -> "schema"
        grid.loading_more -> "loading..."
        grid.has_more -> "scroll for more"
        true -> "all loaded"
      end

    title =
      case Map.get(app, :active_view) do
        :table_view ->
          tbl = Map.get(app, :selected_table)

          if tbl,
            do: "TABLE: #{tbl} (#{row_count_label} - #{more_status})#{sort_badge}#{filter_badge}#{dirty_badge}#{loading_badge}#{mode_badge}",
            else: "TABLE VIEW#{loading_badge}#{mode_badge}"

        :query_view ->
          "QUERY RESULT GRID (#{row_count_label})#{sort_badge}#{dirty_badge}#{mode_badge}"

        _ ->
          "RESULT DATA GRID (#{row_count_label})#{sort_badge}#{dirty_badge}#{mode_badge}"
      end

    viewport_h = max(1, area.height - 3)
    max_top = max(0, total_loaded_rows - viewport_h)

    # Keep scroll_top aligned with r_idx if selecting, to prevent out-of-bounds selection jumps
    scroll_top =
      if grid.mode == :selecting and r_idx != nil do
        cond do
          r_idx < (grid.scroll_offset || 0) ->
            max(0, r_idx)

          r_idx >= (grid.scroll_offset || 0) + viewport_h ->
            min(max_top, r_idx - viewport_h + 1)

          true ->
            min(grid.scroll_offset || 0, max_top)
        end
      else
        min(grid.scroll_offset || 0, max_top)
      end

    display_rows = DataGrid.effective_rows_slice(grid, scroll_top, viewport_h)

    max_width = max(1, area.width - 3)

    all_w = DataGrid.static_widths(grid)
    max_off = DataGrid.max_col_offset(all_w, max_width)
    col_offset = min(grid.col_offset || 0, max_off)
    visible_raw_cols = Enum.slice(grid.columns, col_offset, length(grid.columns))
    col_widths = DataGrid.column_widths_from_all_w(all_w, max_width, col_offset)

    visible_col_count = Enum.count(col_widths, fn w -> w > 0 end)
    visible_columns = Enum.take(visible_raw_cols, visible_col_count)
    active_col_widths = Enum.take(col_widths, visible_col_count)

    widths =
      cond do
        visible_columns == [] ->
          [{:fill, 1}]

        true ->
          {front, [_last_w]} = Enum.split(active_col_widths, -1)
          Enum.map(front, fn w -> {:length, w} end) ++ [{:fill, 1}]
      end

    string_rows =
      display_rows
      |> Enum.with_index()
      |> Enum.map(fn {row, rel_r} ->
        abs_r = scroll_top + rel_r
        deleted? = MapSet.member?(grid.pending_deletes, abs_r)
        inserted? = abs_r >= base_len
        visible_cells = Enum.slice(row, col_offset, visible_col_count)

        visible_cells
        |> Enum.zip(active_col_widths)
        |> Enum.with_index()
        |> Enum.map(fn {{cell_val, col_w}, local_c} ->
          abs_c = col_offset + local_c
          render_w = if local_c == visible_col_count - 1, do: max(col_w, max_width), else: col_w

          cond do
            deleted? ->
              format_staged_cell_span(cell_val, render_w, :deleted, local_c == 0)

            inserted? ->
              format_staged_cell_span(cell_val, render_w, :inserted, local_c == 0)

            Map.has_key?(grid.pending_edits, {abs_r, abs_c}) ->
              format_staged_cell_span(cell_val, render_w, :edited, true)

            true ->
              Strata.Formatter.format_cell_span(cell_val, render_w)
          end
        end)
      end)

    string_header =
      Enum.map(visible_columns, fn col_name ->
        name_str = to_string(col_name)

        case grid.sort_by do
          {^name_str, :asc} -> name_str <> " ▲"
          {^name_str, :desc} -> name_str <> " ▼"
          _ -> name_str
        end
      end)

    local_row_idx = (r_idx || 0) - scroll_top
    local_col_idx = (c_idx || 0) - col_offset

    selected_row =
      if grid.mode == :selecting and string_rows != [] and local_row_idx >= 0 and local_row_idx < length(string_rows) do
        local_row_idx
      else
        nil
      end

    selected_col =
      if grid.mode == :selecting and visible_columns != [] and local_col_idx >= 0 and local_col_idx < length(visible_columns) do
        local_col_idx
      else
        nil
      end

    has_left_cols? = col_offset > 0
    has_right_cols? = col_offset + visible_col_count < length(grid.columns)

    scroll_indicator =
      cond do
        has_left_cols? and has_right_cols? -> " [◀ Cols #{col_offset + 1}-#{col_offset + visible_col_count}/#{length(grid.columns)} ▶]"
        has_left_cols? -> " [◀ Cols #{col_offset + 1}-#{col_offset + visible_col_count}/#{length(grid.columns)}]"
        has_right_cols? -> " [Cols 1-#{visible_col_count}/#{length(grid.columns)} ▶]"
        true -> ""
      end

    title_with_indicator = title <> scroll_indicator

    highlight_sym = ""
    highlight_st = if grid.mode == :selecting, do: %ExRatatui.Style{fg: :black, bg: :yellow}, else: %ExRatatui.Style{}
    cell_highlight_st = if grid.mode == :selecting, do: %ExRatatui.Style{fg: :white, bg: :green, modifiers: [:bold]}, else: %ExRatatui.Style{}

    widget = %ExRatatui.Widgets.Table{
      header: if(string_header != [], do: string_header, else: nil),
      rows: string_rows,
      widths: widths,
      selected: selected_row,
      selected_column: selected_col,
      highlight_symbol: highlight_sym,
      highlight_spacing: :never,
      header_style: %ExRatatui.Style{fg: :yellow, modifiers: [:bold]},
      highlight_style: highlight_st,
      cell_highlight_style: cell_highlight_st,
      block: %ExRatatui.Widgets.Block{
        title: " #{title_with_indicator} ",
        borders: [:all],
        border_type: :rounded,
        border_style: %ExRatatui.Style{fg: fg}
      }
    }

    rect = to_rect(area)

    v_scrollbar =
      if total_loaded_rows > viewport_h do
        [
          {%ExRatatui.Widgets.Scrollbar{
             orientation: :vertical_right,
             content_length: max_top,
             position: scroll_top,
             thumb_symbol: "┃",
             track_symbol: "│",
             begin_symbol: "▲",
             end_symbol: "▼",
             thumb_style: %ExRatatui.Style{fg: :yellow, modifiers: [:bold]},
             track_style: %ExRatatui.Style{fg: :dark_gray}
           }, rect}
        ]
      else
        []
      end

    h_scrollbar =
      if length(grid.columns) > visible_col_count do
        max_col_off = DataGrid.max_col_offset(all_w, max_width)

        [
          {%ExRatatui.Widgets.Scrollbar{
             orientation: :horizontal_bottom,
             content_length: max(1, max_col_off),
             position: col_offset,
             thumb_symbol: "━",
             track_symbol: "─",
             begin_symbol: "◀",
             end_symbol: "▶",
             thumb_style: %ExRatatui.Style{fg: :yellow, modifiers: [:bold]},
             track_style: %ExRatatui.Style{fg: :dark_gray}
           }, rect}
        ]
      else
        []
      end

    throbber_overlay =
      if grid.loading_more and grid.columns == ["Status"] and area.width > 16 and area.height > 4 do
        t_rect = %ExRatatui.Layout.Rect{
          x: area.x + 2,
          y: area.y + 3,
          width: max(8, area.width - 4),
          height: 1
        }

        [
          {%ExRatatui.Widgets.Throbber{
             label: "Fetching data from database...",
             throbber_set: :braille,
             step: Map.get(app, :throbber_step, 0),
             style: %ExRatatui.Style{fg: :yellow},
             throbber_style: %ExRatatui.Style{fg: :cyan, modifiers: [:bold]}
           }, t_rect}
        ]
      else
        []
      end

    inline_overlay =
      render_inline_cell_input(
        app,
        grid,
        area,
        scroll_top,
        col_offset,
        active_col_widths
      )

    filter_widgets = render_inline_filter_bar(app, filter_area)
    inspector_widgets = render_inspector_drawer(app, grid, inspector_area)
    dropdown_widgets = render_filter_dropdown(app, total_area)
    sort_picker_widgets = render_sort_picker(app, total_area)

    widgets =
      filter_widgets ++
        [{widget, rect}] ++
        v_scrollbar ++
        h_scrollbar ++
        throbber_overlay ++
        inline_overlay ++
        inspector_widgets ++
        dropdown_widgets ++
        sort_picker_widgets

    case widgets do
      [single] -> single
      list -> list
    end
  end

  @doc """
  Computes the Sort Column Picker dropdown geometry and items when `sort_picker_open`
  is active in Browsing mode. Returns `nil` when closed.
  """
  @spec sort_picker_data(map(), rect()) :: map() | nil
  def sort_picker_data(app, total_area) do
    if Map.get(app, :sort_picker_open, false) do
      %{grid_area: g_area} = datagrid_areas(total_area, app)
      grid = Map.get(app, :datagrid_state) || DataGrid.new()
      search = String.downcase(String.trim(to_string(Map.get(app, :sort_picker_search, ""))))

      col_items =
        grid.columns
        |> Enum.with_index()
        |> Enum.map(fn {col_name, col_idx} ->
          name_str = to_string(col_name)

          dir_suffix =
            case grid.sort_by do
              {^name_str, :asc} -> "  ▲ (ASC)"
              {^name_str, :desc} -> "  ▼ (DESC)"
              _ -> ""
            end

          %{kind: :column, col_idx: col_idx, name: name_str, label: name_str <> dir_suffix}
        end)
        |> Enum.filter(fn item ->
          search == "" or String.contains?(String.downcase(item.name), search)
        end)
        |> Enum.sort_by(fn item ->
          low = String.downcase(item.name)
          if search != "" and String.starts_with?(low, search), do: 0, else: 1
        end)

      items =
        if grid.sort_by != nil and search == "" do
          col_items ++ [%{kind: :clear, col_idx: nil, name: "", label: "✕ Clear Sort"}]
        else
          col_items
        end

      w = min(34, max(20, g_area.width - 4))
      x = g_area.x + 2
      y = min(g_area.y + 2, g_area.y + max(1, g_area.height - 4))
      max_h = max(4, g_area.y + g_area.height - y)
      h = min(min(14, max_h), max(3, length(items) + 2))
      idx = min(max(0, Map.get(app, :sort_picker_idx, 0)), max(0, length(items) - 1))

      %{
        rect: %{x: x, y: y, width: w, height: h},
        items: items,
        selected_index: idx,
        search: Map.get(app, :sort_picker_search, "")
      }
    else
      nil
    end
  end

  defp render_sort_picker(app, total_area) do
    case sort_picker_data(app, total_area) do
      nil ->
        []

      %{rect: rect, items: items, selected_index: idx, search: search} ->
        dd_rect = to_rect(rect)
        clear_w = %ExRatatui.Widgets.Clear{}
        title = if search != "", do: " ↕ Sort: #{search}▏ ", else: " ↕ Sort by Column (Enter/Esc) "

        list_items =
          if items == [] do
            ["(No matching columns)"]
          else
            Enum.map(items, & &1.label)
          end

        list_w = %ExRatatui.Widgets.List{
          items: list_items,
          selected: if(items == [], do: 0, else: idx),
          highlight_symbol: "▸ ",
          highlight_style: %ExRatatui.Style{fg: :black, bg: :yellow, modifiers: [:bold]},
          block: %ExRatatui.Widgets.Block{
            title: title,
            borders: [:all],
            border_type: :rounded,
            border_style: %ExRatatui.Style{fg: :yellow}
          }
        }

        [{clear_w, dd_rect}, {list_w, dd_rect}]
    end
  end

  @doc """
  Computes the floating dropdown geometry and items for the Filter Bar (`:column` or `:op`),
  returning `nil` when closed. Shared with mouse click handling in `App`.
  """
  @spec filter_dropdown_data(map(), rect()) :: map() | nil
  def filter_dropdown_data(app, total_area) do
    kind = Map.get(app, :filter_dropdown)
    filter_open? = Map.get(app, :filter_bar_open, false)
    mode = Map.get(app, :filter_bar_mode, :builder)

    if kind in [:column, :op] and filter_open? and mode == :builder do
      %{filter_area: f_area} = datagrid_areas(total_area, app)

      if f_area do
        rects = filter_bar_rects(f_area, app)
        anchor = if kind == :column, do: rects.col_rect, else: rects.op_rect

        if anchor do
          grid = Map.get(app, :datagrid_state) || DataGrid.new()
          search = String.downcase(String.trim(to_string(Map.get(app, :filter_dropdown_search, ""))))

          items =
            case kind do
              :column ->
                cols = ["* All" | grid.columns || []]

                cols
                |> Enum.map(fn c ->
                  val = to_string(c)
                  lbl = if c == "* All", do: "* All (every column)", else: val
                  %{value: val, label: lbl}
                end)
                |> Enum.filter(fn item ->
                  search == "" or String.contains?(String.downcase(item.value), search)
                end)
                |> Enum.sort_by(fn item ->
                  low = String.downcase(item.value)
                  if search != "" and String.starts_with?(low, search), do: 0, else: 1
                end)

              :op ->
                Enum.map(Strata.QueryBuilder.filter_operators(), fn op ->
                  %{value: op, label: op_dropdown_label(op)}
                end)
            end

          box_w = if kind == :column, do: 30, else: 26
          max_w = max(18, total_area.x + total_area.width - anchor.x - 1)
          w = min(box_w, max_w)
          x = min(anchor.x, max(total_area.x, total_area.x + total_area.width - w - 1))
          y = f_area.y + 3
          max_h = max(4, total_area.y + total_area.height - y)
          h = min(min(12, max_h), max(3, length(items) + 2))

          idx = min(max(0, Map.get(app, :filter_dropdown_idx, 0)), max(0, length(items) - 1))

          %{
            kind: kind,
            rect: %{x: x, y: y, width: w, height: h},
            items: items,
            selected_index: idx,
            search: Map.get(app, :filter_dropdown_search, "")
          }
        else
          nil
        end
      else
        nil
      end
    else
      nil
    end
  end

  defp op_dropdown_label(:contains), do: "contains  (chứa)"
  defp op_dropdown_label(:starts_with), do: "starts with"
  defp op_dropdown_label(:=), do: "=   (equals)"
  defp op_dropdown_label(:!=), do: "!=  (not equals)"
  defp op_dropdown_label(:>), do: ">   (greater)"
  defp op_dropdown_label(:<), do: "<   (less)"
  defp op_dropdown_label(:>=), do: ">=  (greater/eq)"
  defp op_dropdown_label(:<=), do: "<=  (less/eq)"
  defp op_dropdown_label(:is_null), do: "IS NULL"
  defp op_dropdown_label(:is_not_null), do: "IS NOT NULL"
  defp op_dropdown_label(other), do: to_string(other)

  defp render_filter_dropdown(app, total_area) do
    case filter_dropdown_data(app, total_area) do
      nil ->
        []

      %{kind: kind, rect: rect, items: items, selected_index: idx, search: search} ->
        dd_rect = to_rect(rect)
        clear_w = %ExRatatui.Widgets.Clear{}

        title =
          case kind do
            :column when search != "" -> " Column: #{search}▏ "
            :column -> " Select Column (type to search) "
            :op -> " Select Operator "
          end

        list_items =
          if items == [] do
            ["(No matching columns)"]
          else
            Enum.map(items, & &1.label)
          end

        list_w = %ExRatatui.Widgets.List{
          items: list_items,
          selected: if(items == [], do: 0, else: idx),
          highlight_symbol: "▸ ",
          highlight_style: %ExRatatui.Style{fg: :black, bg: :yellow, modifiers: [:bold]},
          block: %ExRatatui.Widgets.Block{
            title: title,
            borders: [:all],
            border_type: :rounded,
            border_style: %ExRatatui.Style{fg: :yellow}
          }
        }

        [{clear_w, dd_rect}, {list_w, dd_rect}]
    end
  end

  @doc """
  Computes sub-widget rectangles inside the inline Filter Bar for both rendering and mouse clicks.
  """
  @spec filter_bar_rects(rect(), map()) :: map()
  def filter_bar_rects(f_area, app) do
    inner_x = f_area.x + 1
    inner_y = f_area.y + 1
    mode = Map.get(app, :filter_bar_mode, :builder)
    mode_label = if mode == :raw, do: "[Builder]", else: "[SQL]"
    mode_w = String.length(mode_label)
    clear_w = 3
    run_w = 5

    right_edge = f_area.x + f_area.width - 1
    mode_x = max(inner_x + 14, right_edge - mode_w)
    clear_x = max(inner_x + 10, mode_x - 1 - clear_w)
    run_x = max(inner_x + 4, clear_x - 1 - run_w)

    mode_rect = %{x: mode_x, y: inner_y, width: mode_w, height: 1}
    clear_rect = %{x: clear_x, y: inner_y, width: clear_w, height: 1}
    run_rect = %{x: run_x, y: inner_y, width: run_w, height: 1}

    avail = max(6, run_x - inner_x - 1)

    if mode == :raw do
      val_rect = %{x: inner_x, y: inner_y, width: avail, height: 1}

      %{
        run_rect: run_rect,
        clear_rect: clear_rect,
        mode_rect: mode_rect,
        val_rect: val_rect,
        col_rect: nil,
        op_rect: nil
      }
    else
      col_str = Map.get(app, :filter_bar_col, "* All") || "* All"
      op = Map.get(app, :filter_bar_op, :contains) || :contains
      op_label = Strata.QueryBuilder.operator_label(op)

      col_text = " #{col_str} ▾ "
      op_text = " #{op_label} ▾ "

      col_w = min(max(10, div(avail, 3)), max(9, String.length(col_text)))
      op_w = min(max(8, div(avail, 4) + 2), max(6, String.length(op_text)))
      val_x = inner_x + col_w + 1 + op_w + 1
      val_w = max(4, run_x - val_x - 1)

      %{
        col_rect: %{x: inner_x, y: inner_y, width: col_w, height: 1},
        op_rect: %{x: inner_x + col_w + 1, y: inner_y, width: op_w, height: 1},
        val_rect: %{x: val_x, y: inner_y, width: val_w, height: 1},
        run_rect: run_rect,
        clear_rect: clear_rect,
        mode_rect: mode_rect
      }
    end
  end

  defp render_inline_filter_bar(_app, nil), do: []

  defp render_inline_filter_bar(app, f_area) do
    focused? = Map.get(app, :filter_bar_focused, false)
    mode = Map.get(app, :filter_bar_mode, :builder)
    focus_part = Map.get(app, :filter_bar_focus_part, :value)
    border_fg = if focused?, do: :yellow, else: :cyan

    title =
      cond do
        not focused? ->
          " 🔍 Active Filter ([f] Edit · [Ctrl+L] Reset · [Esc] Hide) "

        mode == :raw ->
          " 🔍 Raw SQL WHERE (Enter Run · Ctrl+V Paste · Ctrl+R Builder · Ctrl+L Reset) "

        true ->
          " 🔍 Smart Filter (Enter/[Run] Apply · ↑ History · Tab Col/Op/Val · Ctrl+R SQL) "
      end

    f_rect = to_rect(f_area)

    outer_block = %ExRatatui.Widgets.Block{
      title: title,
      borders: [:all],
      border_type: :rounded,
      border_style: %ExRatatui.Style{fg: border_fg}
    }

    rects = filter_bar_rects(f_area, app)

    mode_label = if mode == :raw, do: "[Builder]", else: "[SQL]"

    action_widgets = [
      {%ExRatatui.Widgets.Paragraph{
         text: "[Run]",
         style: %ExRatatui.Style{fg: :black, bg: :green, modifiers: [:bold]}
       }, to_rect(rects.run_rect)},
      {%ExRatatui.Widgets.Paragraph{
         text: "[×]",
         style: %ExRatatui.Style{fg: :white, bg: :red, modifiers: [:bold]}
       }, to_rect(rects.clear_rect)},
      {%ExRatatui.Widgets.Paragraph{
         text: mode_label,
         style: %ExRatatui.Style{fg: :cyan, modifiers: [:bold]}
       }, to_rect(rects.mode_rect)}
    ]

    value_widgets = render_filter_value_widget(app, rects.val_rect, focused?, mode, focus_part)

    builder_widgets =
      case {mode, rects} do
        {:builder, %{col_rect: %{} = col_rect, op_rect: %{} = op_rect}} ->
          col_str = Map.get(app, :filter_bar_col, "* All") || "* All"
          op = Map.get(app, :filter_bar_op, :contains) || :contains
          op_label = Strata.QueryBuilder.operator_label(op)

          col_style =
            if focused? and focus_part == :column,
              do: %ExRatatui.Style{fg: :black, bg: :yellow, modifiers: [:bold]},
              else: %ExRatatui.Style{fg: :white, bg: :dark_gray, modifiers: [:bold]}

          op_style =
            if focused? and focus_part == :op,
              do: %ExRatatui.Style{fg: :black, bg: :yellow, modifiers: [:bold]},
              else: %ExRatatui.Style{fg: :yellow, bg: :dark_gray, modifiers: [:bold]}

          [
            {%ExRatatui.Widgets.Paragraph{text: " #{col_str} ▾ ", style: col_style}, to_rect(col_rect)},
            {%ExRatatui.Widgets.Paragraph{text: " #{op_label} ▾ ", style: op_style}, to_rect(op_rect)}
          ]

        _ ->
          []
      end

    [{outer_block, f_rect}] ++ builder_widgets ++ value_widgets ++ action_widgets
  end

  defp render_filter_value_widget(app, v_rect, focused?, mode, focus_part) do
    op = Map.get(app, :filter_bar_op, :contains)
    no_val_needed? = mode == :builder and op in [:is_null, :is_not_null]
    rect = to_rect(v_rect)

    cond do
      no_val_needed? ->
        [
          {%ExRatatui.Widgets.Paragraph{
             text: "(no value needed — Enter to apply)",
             style: %ExRatatui.Style{fg: :dark_gray}
           }, rect}
        ]

      focused? and (mode == :raw or focus_part == :value) and not is_nil(Map.get(app, :filter_bar_ref)) ->
        [
          {%ExRatatui.Widgets.TextInput{
             state: app.filter_bar_ref,
             style: %ExRatatui.Style{fg: :white, bg: :dark_gray},
             cursor_style: %ExRatatui.Style{fg: :black, bg: :yellow, modifiers: [:bold]}
           }, rect}
        ]

      true ->
        raw_txt = Map.get(app, :filter_bar_text, "")
        placeholder = if mode == :raw, do: "e.g. status = 'active' AND id > 10", else: "type value to filter..."
        txt = if raw_txt == "", do: placeholder, else: raw_txt
        style = if raw_txt == "", do: %ExRatatui.Style{fg: :dark_gray}, else: %ExRatatui.Style{fg: :white}

        [{%ExRatatui.Widgets.Paragraph{text: txt, style: style}, rect}]
    end
  end

  defp render_inspector_drawer(_app, _grid, nil), do: []

  defp render_inspector_drawer(app, grid, i_area) do
    data = inspector_data(app, grid, i_area)
    v_area = data.areas.value_area
    s_area = data.areas.summary_area

    v_scroll = min(Map.get(app, :inspector_value_scroll, 0) || 0, data.max_value_scroll)
    v_visible = data.value_lines |> Enum.drop(v_scroll) |> Enum.take(data.val_viewport_h)

    v_scroll_hint =
      if data.max_value_scroll > 0,
        do: " #{v_scroll + 1}/#{length(data.value_lines)}",
        else: ""

    value_widget = %ExRatatui.Widgets.Paragraph{
      text: v_visible,
      block: %ExRatatui.Widgets.Block{
        title: " 🔍 #{data.col_name} [#{data.fmt_badge}]#{v_scroll_hint} [I/Esc] ",
        borders: [:all],
        border_type: :rounded,
        border_style: %ExRatatui.Style{fg: :cyan}
      }
    }

    v_rect = to_rect(v_area)

    value_scrollbar =
      if data.max_value_scroll > 0 do
        [
          {%ExRatatui.Widgets.Scrollbar{
             orientation: :vertical_right,
             content_length: max(1, data.max_value_scroll),
             position: v_scroll,
             thumb_symbol: "┃",
             track_symbol: "│",
             thumb_style: %ExRatatui.Style{fg: :yellow},
             track_style: %ExRatatui.Style{fg: :dark_gray}
           }, v_rect}
        ]
      else
        []
      end

    summary_widgets =
      if s_area do
        s_scroll = min(Map.get(app, :inspector_summary_scroll, 0) || 0, data.max_summary_scroll)
        s_visible = data.summary_lines |> Enum.drop(s_scroll) |> Enum.take(data.sum_viewport_h)
        s_rect = to_rect(s_area)

        s_scroll_hint =
          if data.max_summary_scroll > 0,
            do: " [#{s_scroll + 1}/#{length(data.summary_lines)}]",
            else: ""

        sum_widget = %ExRatatui.Widgets.Paragraph{
          text: s_visible,
          block: %ExRatatui.Widgets.Block{
            title: " 📋 Row #{data.row_idx + 1}/#{data.total_rows} Summary#{s_scroll_hint} ",
            borders: [:all],
            border_type: :rounded,
            border_style: %ExRatatui.Style{fg: :cyan}
          }
        }

        sum_scrollbar =
          if data.max_summary_scroll > 0 do
            [
              {%ExRatatui.Widgets.Scrollbar{
                 orientation: :vertical_right,
                 content_length: max(1, data.max_summary_scroll),
                 position: s_scroll,
                 thumb_symbol: "┃",
                 track_symbol: "│",
                 thumb_style: %ExRatatui.Style{fg: :yellow},
                 track_style: %ExRatatui.Style{fg: :dark_gray}
               }, s_rect}
            ]
          else
            []
          end

        [{sum_widget, s_rect}] ++ sum_scrollbar
      else
        []
      end

    [{value_widget, v_rect}] ++ value_scrollbar ++ summary_widgets
  end

  defp format_staged_cell_span(val, col_w, kind, show_marker?) do
    style =
      case kind do
        :edited -> %ExRatatui.Style{fg: :yellow, modifiers: [:bold]}
        :inserted -> %ExRatatui.Style{fg: :green, modifiers: [:bold]}
        :deleted -> %ExRatatui.Style{fg: :red, modifiers: [:crossed_out]}
      end

    marker =
      if show_marker? and col_w >= 4 do
        case kind do
          :edited -> "* "
          :inserted -> "+ "
          :deleted -> "- "
        end
      else
        ""
      end

    inner_w = max(1, col_w - String.length(marker))
    base_span = Strata.Formatter.format_cell_span(val, inner_w)
    ExRatatui.Text.Span.new(marker <> base_span.content, style: style)
  end

  defp render_inline_cell_input(
         %{inline_input_ref: ref},
         %DataGrid{editing_cell: {edit_r, edit_c}},
         area,
         scroll_top,
         col_offset,
         active_col_widths
       )
       when not is_nil(ref) do
    edit_rel_r = edit_r - scroll_top
    edit_local_c = edit_c - col_offset
    viewport_h = max(1, area.height - 3)

    if edit_rel_r >= 0 and edit_rel_r < viewport_h and edit_local_c >= 0 and
         edit_local_c < length(active_col_widths) do
      offset_x =
        active_col_widths
        |> Enum.take(edit_local_c)
        |> Enum.reduce(0, fn w, acc -> acc + w + 1 end)

      cell_x = area.x + 1 + offset_x
      cell_y = area.y + 2 + edit_rel_r
      right_edge = area.x + area.width - 1

      raw_w =
        if edit_local_c == length(active_col_widths) - 1 do
          max(4, right_edge - cell_x)
        else
          Enum.at(active_col_widths, edit_local_c, 12)
        end

      cell_w = min(max(2, raw_w), max(2, right_edge - cell_x))

      input_rect = %ExRatatui.Layout.Rect{
        x: cell_x,
        y: cell_y,
        width: cell_w,
        height: 1
      }

      clear_widget = %ExRatatui.Widgets.Clear{}

      input_widget = %ExRatatui.Widgets.TextInput{
        state: ref,
        style: %ExRatatui.Style{fg: :black, bg: :yellow},
        cursor_style: %ExRatatui.Style{fg: :black, bg: :white, modifiers: [:bold]}
      }

      [{clear_widget, input_rect}, {input_widget, input_rect}]
    else
      []
    end
  end

  defp render_inline_cell_input(_app, _grid, _area, _scroll_top, _col_offset, _widths), do: []

  defp render_footer(app, area) do
    alias ExRatatui.Style
    alias ExRatatui.Text.{Line, Span}

    footer_chunk = Footer.render(app, area)
    status = Map.get(footer_chunk, :status_message)

    line =
      if is_binary(status) and status != "" and status != "Ready" do
        status_style =
          cond do
            String.contains?(status, ["❌", "Error", "failed"]) ->
              %Style{fg: :white, bg: :red, modifiers: [:bold]}

            String.contains?(status, ["⏳", "Loading", "Executing"]) ->
              %Style{fg: :black, bg: :yellow, modifiers: [:bold]}

            true ->
              %Style{fg: :black, bg: :cyan, modifiers: [:bold]}
          end

        total_w = max(20, Map.get(area, :width, 120))
        status_badge = " #{status} "
        max_status_w = max(16, total_w - 4)

        clipped_status =
          if String.length(status_badge) > max_status_w do
            String.slice(status_badge, 0, max_status_w - 3) <> "... "
          else
            status_badge
          end

        avail_shortcuts = total_w - String.length(clipped_status) - 1

        if avail_shortcuts >= 12 do
          sc_part = " " <> footer_chunk.shortcuts_text <> "  "

          sc_clipped =
            if String.length(sc_part) > avail_shortcuts do
              String.slice(sc_part, 0, avail_shortcuts)
            else
              sc_part
            end

          Line.new([
            Span.new(sc_clipped, style: %Style{fg: :black, bg: :white}),
            Span.new(clipped_status, style: status_style)
          ])
        else
          Line.new([
            Span.new(clipped_status, style: status_style)
          ])
        end
      else
        Line.new([
          Span.new(" " <> footer_chunk.text, style: %Style{fg: :black, bg: :white})
        ])
      end

    widget = %ExRatatui.Widgets.Paragraph{
      text: [line],
      style: %ExRatatui.Style{fg: :black, bg: :white}
    }

    {widget, to_rect(area)}
  end

  @doc """
  Computes the modal rect for the top active modal based on its type.
  Shared with `App.handle_mouse/2` for outside-click dismissal.
  """
  def modal_area_for(%{modals: [top | _]}, window_size) do
    dims =
      cond do
        match?(%Strata.UI.Components.ActionsModal{}, top) ->
          {64, max(10, min(22, length(top.items) + 4))}

        match?(%Strata.UI.Components.FilterExportModal{}, top) or match?(%{type: :filter_modal}, top) or match?(%{type: :export_modal}, top) ->
          {74, 18}

        match?(%Strata.UI.Components.ConnectionModal{}, top) or match?(%{type: :connection_modal}, top) ->
          {72, 22}

        match?(%Strata.UI.Components.SSHModal{}, top) or match?(%{type: :ssh_modal}, top) ->
          {72, 22}

        match?(%Strata.UI.Components.CellDetailModal{}, top) or match?(%{type: :cell_detail_modal}, top) ->
          {76, 22}

        match?(%{type: :confirm_delete_connection}, top) ->
          {54, 9}

        true ->
          {64, 18}
      end

    modal_layout(window_size, dims)
  end

  def modal_area_for(_app, window_size), do: modal_layout(window_size, {64, 18})

  defp render_modal(app, window_size) do
    case app.modals do
      [%Strata.UI.Components.ActionsModal{} = actions_modal | _] ->
        modal_area = modal_area_for(app, window_size)
        m_rect = to_rect(modal_area)
        clear_widget = %ExRatatui.Widgets.Clear{}

        list_items =
          Enum.map(actions_modal.items, fn item ->
            "#{String.pad_trailing(item.label, 42)} [#{item.shortcut}]"
          end)

        list_widget = %ExRatatui.Widgets.List{
          items: list_items,
          selected: actions_modal.selected_index,
          highlight_symbol: "▸ ",
          highlight_style: %ExRatatui.Style{fg: :black, bg: :yellow, modifiers: [:bold]},
          block: %ExRatatui.Widgets.Block{
            title: " ⚡ Actions Menu (↑/↓ · Enter run · Esc close) ",
            borders: [:all],
            border_type: :rounded,
            border_style: %ExRatatui.Style{fg: :cyan}
          }
        }

        [{clear_widget, m_rect}, {list_widget, m_rect}]

      [top | _] ->
        modal_area = modal_area_for(app, window_size)
        m_rect = to_rect(modal_area)

        rendered_info =
          case top do
            %Strata.UI.Components.ConnectionModal{} = conn_modal ->
              Strata.UI.Components.ConnectionModal.render(conn_modal, modal_area)

            %{type: :connection_modal} ->
              Strata.UI.Components.ConnectionModal.render(Strata.UI.Components.ConnectionModal.new(), modal_area)

            %Strata.UI.Components.CellDetailModal{} = cell_modal ->
              Strata.UI.Components.CellDetailModal.render(cell_modal, modal_area)

            %{type: :cell_detail_modal} = m ->
              val = Map.get(m, :content, "")
              opts = [column: Map.get(m, :column), row_index: Map.get(m, :row_index)]
              Strata.UI.Components.CellDetailModal.render(Strata.UI.Components.CellDetailModal.new(val, opts), modal_area)

            %Strata.UI.Components.FilterExportModal{} = fe_modal ->
              Strata.UI.Components.FilterExportModal.render(fe_modal, modal_area)

            %{type: :filter_modal} ->
              Strata.UI.Components.FilterExportModal.render(Strata.UI.Components.FilterExportModal.new(:filter), modal_area)

            %{type: :export_modal} ->
              Strata.UI.Components.FilterExportModal.render(Strata.UI.Components.FilterExportModal.new(:export), modal_area)

            %Strata.UI.Components.SSHModal{} = ssh_modal ->
              Strata.UI.Components.SSHModal.render(ssh_modal, modal_area)

            %{type: :ssh_modal} ->
              Strata.UI.Components.SSHModal.render(Strata.UI.Components.SSHModal.new(), modal_area)

            map when is_map(map) ->
              map

            other ->
              %{title: "Modal", content: inspect(other)}
          end

        alias ExRatatui.Style
        alias ExRatatui.Text.{Line, Span}

        raw_title = Map.get(rendered_info, :title)
        title = if is_binary(raw_title) and raw_title != "", do: raw_title, else: "Modal"
        focused = Map.get(rendered_info, :focused_field)

        content_lines =
          case Map.get(rendered_info, :fields) do
            fields when is_list(fields) ->
              Enum.map(fields, fn f ->
                focused? = f.key == focused
                prefix = if focused?, do: " ▸ ", else: "   "

                cond do
                  Map.has_key?(f, :value) ->
                    label = String.pad_trailing(to_string(f.label), 17)
                    val = to_string(f.value || "")

                    if focused? do
                      Line.new([
                        Span.new(prefix <> label <> ": ", style: %Style{fg: :yellow, modifiers: [:bold]}),
                        Span.new(val, style: %Style{fg: :black, bg: :yellow, modifiers: [:bold]})
                      ])
                    else
                      Line.new([
                        Span.new(prefix <> label <> ": ", style: %Style{fg: :cyan}),
                        Span.new(val, style: %Style{fg: :white})
                      ])
                    end

                  focused? ->
                    Line.new([Span.new(prefix <> to_string(f.label), style: %Style{fg: :black, bg: :yellow, modifiers: [:bold]})])

                  true ->
                    btn_fg = if String.contains?(to_string(f.label), "Delete"), do: :red, else: :white
                    Line.new([Span.new(prefix <> to_string(f.label), style: %Style{fg: btn_fg, modifiers: [:bold]})])
                end
              end)

            _ ->
              raw_content =
                case Map.get(rendered_info, :content) do
                  content when is_binary(content) -> content
                  other -> to_string(other || inspect(top))
                end

              cond do
                match?(%{format: :json}, rendered_info) ->
                  body_text =
                    raw_content
                    |> String.split("\n─────", parts: 2)
                    |> List.first()

                  hint_part =
                    case String.split(raw_content, "\n─────", parts: 2) do
                      [_, hint] -> [Line.new([Span.new("─────" <> hint, style: %Style{fg: :dark_gray})])]
                      _ -> []
                    end

                  max_mw = max(12, modal_area.width - 4)
                  Strata.Formatter.highlight_json_lines(body_text, max_mw) ++ hint_part

                true ->
                  raw_content
                  |> String.split("\n")
                  |> Enum.map(fn ln -> Line.new([Span.new(ln)]) end)
              end
          end

        status_lines =
          case Map.get(rendered_info, :status_message) do
            msg when is_binary(msg) and msg != "" ->
              st =
                cond do
                  String.contains?(msg, ["❌", "failed", "Error"]) -> %Style{fg: :red, modifiers: [:bold]}
                  String.contains?(msg, ["⏳", "Testing"]) -> %Style{fg: :yellow, modifiers: [:bold]}
                  true -> %Style{fg: :green, modifiers: [:bold]}
                end

              [Line.new([]), Line.new([Span.new("   " <> msg, style: st)])]

            _ ->
              []
          end

        clear_widget = %ExRatatui.Widgets.Clear{}

        modal_widget = %ExRatatui.Widgets.Paragraph{
          text: content_lines ++ status_lines,
          block: %ExRatatui.Widgets.Block{
            title: " #{title} ",
            borders: [:all],
            border_type: :rounded,
            border_style: %ExRatatui.Style{fg: :cyan}
          }
        }

        [{clear_widget, m_rect}, {modal_widget, m_rect}]

      [] ->
        []
    end
  end

  @doc """
  Converts rendered component tree into ANSI terminal string representation.
  """
  def to_ansi(app) do
    {width, _height} = app.window_size

    header_line = "\e[1;44;37m 🗄️  Strata TUI — Database Manager \e[0m" <> String.duplicate(" ", max(0, width - 36)) <> "\n"

    sidebar_lines =
      Sidebar.flatten_visible_nodes(app.sidebar_nodes, app.selected_tree_node_id)
      |> Enum.map_join("\n", fn n -> "  #{n.label}" end)

    sidebar_text = " [🔌 CONNECTIONS]\n" <> if(sidebar_lines != "", do: sidebar_lines <> "\n", else: "  (No connections configured)\n")

    active_tab = Enum.find(app.tabs, &(&1.id == app.active_tab_id)) || List.first(app.tabs)
    sql_text = if active_tab, do: active_tab.content, else: ""
    editor_text = " [📜 SQL EDITOR]\n  1 │ #{sql_text}\n"

    grid_count = if app.datagrid_state, do: length(app.datagrid_state.rows), else: 0
    datagrid_text = " [📊 DATA GRID (#{grid_count} rows)]\n" <> if(grid_count == 0, do: "  (No data loaded)\n", else: "  #{grid_count} rows in grid\n")

    footer_text = "\n\e[7m [1] Table  [2] SQL  [3] Data  [a] Add Conn  [q] Quit \e[0m"

    header_line <> sidebar_text <> "\n" <> editor_text <> "\n" <> datagrid_text <> footer_text
  end
end

