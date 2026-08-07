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

    List.flatten([header_item, sidebar_item, editor_item, datagrid_item, footer_item] ++ modal_items)
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
    sidebar_chunk = Sidebar.render(app, area)
    fg = if app.focus == :sidebar, do: :yellow, else: :cyan

    # Manually manage scrolling: slice items to the visible viewport
    all_items = sidebar_chunk.items
    total = length(all_items)
    viewport_h = max(1, area.height - 2)
    scroll_offset = Map.get(app, :sidebar_scroll_offset, 0)
    max_offset = max(0, total - viewport_h)
    clamped_offset = min(scroll_offset, max_offset)

    visible_items = Enum.slice(all_items, clamped_offset, viewport_h)

    # Adjust selected index relative to the visible slice
    global_selected = sidebar_chunk.selected_index || 0
    local_selected =
      if global_selected >= clamped_offset and global_selected < clamped_offset + viewport_h do
        global_selected - clamped_offset
      else
        nil
      end

    list_widget = %ExRatatui.Widgets.List{
      items: visible_items,
      selected: local_selected,
      highlight_symbol: "> ",
      highlight_style: %ExRatatui.Style{fg: :yellow},
      scroll_padding: 0,
      block: %ExRatatui.Widgets.Block{
        title: " CONNECTIONS / SCHEMA ",
        borders: [:all],
        border_style: %ExRatatui.Style{fg: fg}
      }
    }

    scrollbar_widget = %ExRatatui.Widgets.Scrollbar{
      orientation: :vertical_right,
      content_length: max(1, total),
      position: clamped_offset,
      viewport_content_length: max(1, viewport_h),
      thumb_style: %ExRatatui.Style{fg: :yellow},
      track_style: %ExRatatui.Style{fg: :dark_gray}
    }

    rect = to_rect(area)
    [{list_widget, rect}, {scrollbar_widget, rect}]
  end

  defp render_editor(app, area) do
    if area.height > 0 do
      editor_chunk = SQLEditor.render(app, area)
      lines = Enum.map_join(editor_chunk.lines, "\n", fn l -> l.prefix <> l.text end)
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

      paragraph_widget = %ExRatatui.Widgets.Paragraph{
        text: lines,
        block: %ExRatatui.Widgets.Block{
          title: " SQL EDITOR ",
          borders: [:all],
          border_style: %ExRatatui.Style{fg: fg}
        }
      }

      comp = Map.get(editor_chunk, :completion, %{})

      completion_items =
        if comp != %{} and Map.get(comp, :active?, false) and Map.get(comp, :suggestions, []) != [] do
          suggs = comp.suggestions
          sel_idx = comp.selected_index || 0
          {c_row, c_col} = Map.get(editor_chunk, :cursor, {0, 0})

          popup_width = 24
          popup_height = min(7, length(suggs) + 2)

          px = min(area.x + area.width - popup_width, area.x + c_col + 6)
          py = min(area.y + area.height - popup_height, area.y + c_row + 2)

          popup_rect = %ExRatatui.Layout.Rect{
            x: max(area.x, px),
            y: max(area.y, py),
            width: popup_width,
            height: popup_height
          }

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
              border_style: %ExRatatui.Style{fg: :yellow}
            }
          }

          [{clear_w, popup_rect}, {list_w, popup_rect}]
        else
          []
        end

      [{tabs_widget, tabs_rect}, {paragraph_widget, body_rect}] ++ completion_items
    else
      widget = %ExRatatui.Widgets.Paragraph{text: ""}
      {widget, to_rect(area)}
    end
  end

  defp render_datagrid(app, area) do
    grid = app.datagrid_state || DataGrid.new()
    all_rows = grid.rows
    {r_idx, c_idx} = grid.selected_cell
    fg = if app.focus == :datagrid, do: :yellow, else: :cyan

    mode_badge = if grid.mode == :selecting, do: " [SELECT MODE] ", else: " [BROWSING - Press 'v' to Select] "
    loading_badge = if grid.loading_more, do: " [⏳ Loading more...] ", else: ""
    total_loaded_rows = grid.total_rows || length(all_rows)

    more_status =
      cond do
        grid.loading_more -> "loading..."
        grid.has_more -> "scroll for more"
        true -> "all loaded"
      end

    title =
      case Map.get(app, :active_view) do
        :table_view ->
          tbl = Map.get(app, :selected_table)

          if tbl,
            do: "TABLE VIEW: #{tbl} (#{total_loaded_rows} rows - #{more_status})#{loading_badge}#{mode_badge}",
            else: "TABLE VIEW#{loading_badge}#{mode_badge}"

        :query_view ->
          "QUERY RESULT GRID (#{total_loaded_rows} rows)#{mode_badge}"

        _ ->
          "RESULT DATA GRID (#{total_loaded_rows} rows)#{mode_badge}"
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

    display_rows = Enum.slice(all_rows, scroll_top, viewport_h)

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
      Enum.map(display_rows, fn row ->
        visible_cells = Enum.slice(row, col_offset, visible_col_count)

        Enum.zip(visible_cells, active_col_widths)
        |> Enum.map(fn {cell_val, col_w} ->
          Strata.Formatter.format_cell_span(cell_val, col_w)
        end)
      end)

    string_header =
      Enum.map(visible_columns, fn col_name ->
        to_string(col_name)
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
        has_left_cols? and has_right_cols? -> " [◀ Cols #{col_offset + 1}-#{col_offset + visible_col_count}/#{length(grid.columns)} ▶] "
        has_left_cols? -> " [◀ Cols #{col_offset + 1}-#{col_offset + visible_col_count}/#{length(grid.columns)}] "
        has_right_cols? -> " [Cols 1-#{visible_col_count}/#{length(grid.columns)} ▶] "
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
        border_style: %ExRatatui.Style{fg: fg}
      }
    }

    rect = to_rect(area)

    v_scrollbar =
      if length(all_rows) > viewport_h do
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
        max_col_off = DataGrid.max_col_offset(grid.columns, all_rows, max_width)

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

    widgets = [{widget, rect}] ++ v_scrollbar ++ h_scrollbar

    case widgets do
      [single] -> single
      list -> list
    end
  end

  defp render_footer(app, area) do
    footer_chunk = Footer.render(app, area)

    widget = %ExRatatui.Widgets.Paragraph{
      text: " " <> footer_chunk.text,
      style: %ExRatatui.Style{fg: :black, bg: :white}
    }

    {widget, to_rect(area)}
  end

  defp render_modal(app, window_size) do
    case app.modals do
      [top | _] ->
        modal_area = modal_layout(window_size, {64, 18})
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

            map when is_map(map) ->
              map

            other ->
              %{title: "Modal", content: inspect(other)}
          end

        raw_title = Map.get(rendered_info, :title)
        title = if is_binary(raw_title) and raw_title != "", do: raw_title, else: "Modal"
        focused = Map.get(rendered_info, :focused_field)

        lines =
          case Map.get(rendered_info, :fields) do
            fields when is_list(fields) ->
              Enum.map_join(fields, "\n", fn f ->
                prefix = if f.key == focused, do: " ▶ ", else: "   "
                label = String.pad_trailing(to_string(f.label), 18)

                if Map.has_key?(f, :value) do
                  val = to_string(f.value || "")
                  "#{prefix}#{label}: #{val}"
                else
                  "#{prefix}#{f.label}"
                end
              end)

            _ ->
              case Map.get(rendered_info, :content) do
                content when is_binary(content) -> content
                other -> to_string(other || inspect(top))
              end
          end

        status_msg =
          case Map.get(rendered_info, :status_message) do
            msg when is_binary(msg) and msg != "" -> "\n\n  " <> msg
            _ -> ""
          end

        full_text = to_string(lines || "") <> status_msg

        clear_widget = %ExRatatui.Widgets.Clear{}

        modal_widget = %ExRatatui.Widgets.Paragraph{
          text: full_text,
          block: %ExRatatui.Widgets.Block{
            title: " #{title} ",
            borders: [:all],
            border_style: %ExRatatui.Style{fg: :magenta}
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

