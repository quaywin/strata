defmodule Strata.UI.Renderer do
  @moduledoc """
  Ratatui layout dispatcher and component tree renderer helper.
  Partitions terminal window into grid chunks and dispatches rendering for panes and modals.
  """

  alias Strata.UI.Components.AIChatPanel
  alias Strata.UI.Components.DataGrid
  alias Strata.UI.Components.Footer
  alias Strata.UI.Components.Sidebar
  alias Strata.UI.Components.SQLEditor

  @type rect :: %{
          x: non_neg_integer(),
          y: non_neg_integer(),
          width: pos_integer(),
          height: pos_integer()
        }

  @doc """
  Computes layout grid rectangles for main UI panes based on window size `{width, height}`,
  `active_view`, and optional `[ai_panel_open: boolean()]`.
  """
  @spec layout({pos_integer(), pos_integer()}, :table_view | :query_view, keyword()) :: map()
  def layout(window_size, active_view \\ :query_view, opts \\ [])

  def layout({width, height}, active_view, opts)
      when is_integer(width) and is_integer(height) do
    footer_height = 1

    content_height = max(1, height - footer_height)

    sidebar_width = max(24, min(40, round(width * 0.25)))
    right_width = max(1, width - sidebar_width)
    tab_bar_height = 1
    right_body_height = max(1, content_height - tab_bar_height)
    right_body_y = tab_bar_height

    ai_open? =
      active_view == :query_view and Keyword.get(opts, :ai_panel_open, false) and
        right_width >= 58

    {editor_height, datagrid_height, datagrid_y} =
      case active_view do
        :table_view ->
          {0, right_body_height, right_body_y}

        _ ->
          eh = max(3, round(right_body_height * 0.40))
          dh = max(1, right_body_height - eh)
          {eh, dh, right_body_y + eh}
      end

    {editor_width, ai_panel} =
      if ai_open? do
        ai_w = min(48, max(30, round(right_width * 0.38)))
        ed_w = max(24, right_width - ai_w)

        panel = %{
          x: sidebar_width + ed_w,
          y: right_body_y,
          width: ai_w,
          height: editor_height
        }

        {ed_w, panel}
      else
        {right_width, nil}
      end

    %{
      header: %{x: 0, y: 0, width: width, height: 0},
      sidebar: %{x: 0, y: 0, width: sidebar_width, height: content_height},
      tabs: %{x: sidebar_width, y: 0, width: right_width, height: tab_bar_height},
      editor: %{
        x: sidebar_width,
        y: right_body_y,
        width: editor_width,
        height: editor_height
      },
      datagrid: %{
        x: sidebar_width,
        y: datagrid_y,
        width: right_width,
        height: datagrid_height
      },
      ai_panel: ai_panel,
      footer: %{
        x: 0,
        y: height - footer_height,
        width: width,
        height: footer_height
      }
    }
  end

  @doc """
  Computes layout grid rectangles from the current `app` state (including `ai_panel_open`).
  """
  @spec layout_for(map()) :: map()
  def layout_for(app) do
    layout(
      Map.get(app, :window_size, {120, 40}),
      Map.get(app, :active_view, :query_view),
      ai_panel_open: Map.get(app, :ai_panel_open, false)
    )
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
    render_scene(app).widgets
  end

  @doc """
  Renders the complete UI component tree alongside per-pane soft-wrap metadata
  (`wrapped_regions`) so `Strata.UI.Selection` preserves line-break provenance
  without duplicating formatting or wrapping logic.
  """
  def render_scene(app) do
    areas = layout_for(app)

    header_item = render_header(app, areas.header)
    sidebar_item = render_sidebar(app, areas.sidebar)
    tabs_item = render_tab_bar(app, areas.tabs)
    {editor_item, editor_regions} = render_editor_with_meta(app, areas.editor)
    {datagrid_item, datagrid_regions} = render_datagrid_with_meta(app, areas.datagrid)

    ai_panel_items =
      case Map.get(areas, :ai_panel) do
        %{} = ai_area ->
          active_id = Map.get(app, :active_tab_id)
          tab = Enum.find(Map.get(app, :tabs, []), &(Map.get(&1, :id) == active_id))
          AIChatPanel.render(app, tab, ai_area)

        nil ->
          []
      end

    footer_item = render_footer(app, areas.footer)

    {modal_items, modal_regions} = render_modal_with_meta(app, app.window_size)

    selection_items =
      case {Map.get(app, :text_selection), Map.get(app, :selection_screen),
            Map.get(app, :selection_bounds)} do
        {{anchor, current}, %{} = screen, %{} = bounds} ->
          Strata.UI.Selection.render_overlays(screen, anchor, current, bounds)

        _ ->
          []
      end

    widgets =
      List.flatten(
        [header_item, sidebar_item, tabs_item, editor_item, datagrid_item] ++
          ai_panel_items ++ [footer_item] ++ modal_items ++ selection_items
      )

    %{
      widgets: widgets,
      wrapped_regions: editor_regions ++ datagrid_regions ++ modal_regions
    }
  end

  defp tab_label_parts(tab, active_id) do
    kind = Map.get(tab, :kind, :query)
    active? = tab.id == active_id

    # Single-column BMP symbols guarantee display width == String.length for exact click hit-testing
    icon = if kind == :table, do: "⊞", else: "⌘"
    prefix = if active?, do: " * ", else: " "
    raw_name = to_string(Map.get(tab, :name, "Tab"))

    short_name =
      if String.length(raw_name) > 20,
        do: String.slice(raw_name, 0, 17) <> "...",
        else: raw_name

    main = "#{prefix}#{icon} #{short_name} "
    close = "[×] "
    {main, close, String.length(main) + String.length(close)}
  end

  @doc """
  Computes exact screen rects for each open tab, its `[×]` close button, the
  `[+ SQL]` action button, and the `[AI]` assistant button inside `tabs_area`.
  Shared between `render_tab_bar/2` and mouse click handling in `Strata.UI.App`.
  """
  @spec tab_bar_layout(map(), rect()) :: %{
          tabs: [map()],
          new_sql_rect: rect() | nil,
          ai_sql_rect: rect() | nil
        }
  def tab_bar_layout(app, tabs_area) do
    tabs = Map.get(app, :tabs, [])
    active_id = Map.get(app, :active_tab_id)
    new_btn_label = " [+ SQL] "
    new_btn_w = String.length(new_btn_label)
    ai_btn_label = " [AI] "
    ai_btn_w = String.length(ai_btn_label)
    max_tabs_right = tabs_area.x + tabs_area.width - new_btn_w - ai_btn_w - 1

    visible_tabs = window_tabs_to_fit(tabs, active_id, max(14, max_tabs_right - tabs_area.x))

    {rev_items, cursor_x} =
      Enum.reduce(visible_tabs, {[], tabs_area.x}, fn tab, {acc, x_acc} ->
        kind = Map.get(tab, :kind, :query)
        active? = tab.id == active_id
        {main, close, w} = tab_label_parts(tab, active_id)
        label = main <> close

        if x_acc + w <= max_tabs_right or acc == [] do
          clamped_w = min(w, max(1, tabs_area.x + tabs_area.width - x_acc))
          rect = %{x: x_acc, y: tabs_area.y, width: clamped_w, height: 1}
          close_len = String.length(close)

          close_rect =
            if clamped_w >= close_len do
              %{x: x_acc + clamped_w - close_len, y: tabs_area.y, width: 3, height: 1}
            else
              %{x: x_acc + max(0, clamped_w - 1), y: tabs_area.y, width: 1, height: 1}
            end

          item = %{
            id: tab.id,
            kind: kind,
            active?: active?,
            label: String.slice(label, 0, clamped_w),
            rect: rect,
            close_rect: close_rect
          }

          {[item | acc], x_acc + clamped_w + 1}
        else
          {acc, x_acc}
        end
      end)

    new_sql_rect =
      if cursor_x + new_btn_w <= tabs_area.x + tabs_area.width do
        %{x: cursor_x, y: tabs_area.y, width: new_btn_w, height: 1}
      else
        nil
      end

    ai_x = if new_sql_rect, do: cursor_x + new_btn_w, else: cursor_x

    ai_sql_rect =
      if ai_x + ai_btn_w <= tabs_area.x + tabs_area.width do
        %{x: ai_x, y: tabs_area.y, width: ai_btn_w, height: 1}
      else
        nil
      end

    %{tabs: Enum.reverse(rev_items), new_sql_rect: new_sql_rect, ai_sql_rect: ai_sql_rect}
  end

  defp window_tabs_to_fit([], _active_id, _avail_w), do: []

  defp window_tabs_to_fit(tabs, active_id, avail_w) do
    active_idx = Enum.find_index(tabs, &(&1.id == active_id)) || 0

    widths =
      Enum.map(tabs, fn tab ->
        {_main, _close, w} = tab_label_parts(tab, active_id)
        w
      end)

    total = Enum.sum(widths) + max(0, length(tabs) - 1)

    if total <= avail_w do
      tabs
    else
      # Slide start index forward until active tab fits within avail_w
      Stream.iterate(0, &(&1 + 1))
      |> Enum.find_value(Enum.slice(tabs, active_idx, 1), fn start_idx ->
        slice = Enum.slice(tabs, start_idx..active_idx)
        slice_w = Enum.sum(Enum.slice(widths, start_idx..active_idx)) + max(0, length(slice) - 1)

        if slice_w <= avail_w or start_idx >= active_idx do
          # Also include trailing tabs if space remains
          {rev_out, _} =
            tabs
            |> Enum.drop(start_idx)
            |> Enum.reduce({[], 0}, fn t, {acc, used} ->
              w = Enum.at(widths, Enum.find_index(tabs, &(&1.id == t.id)) || 0, 12)
              sep = if acc == [], do: 0, else: 1

              if used + sep + w <= avail_w or acc == [] do
                {[t | acc], used + sep + w}
              else
                {acc, used}
              end
            end)

          Enum.reverse(rev_out)
        end
      end)
    end
  end

  defp render_tab_bar(app, tabs_area) do
    alias ExRatatui.Style
    alias ExRatatui.Text.{Line, Span}

    tb = tab_bar_layout(app, tabs_area)

    bg_widget =
      {%ExRatatui.Widgets.Paragraph{
         text: "",
         style: %Style{fg: :gray, bg: :black}
       }, to_rect(tabs_area)}

    tab_widgets =
      Enum.flat_map(tb.tabs, fn item ->
        style =
          cond do
            item.active? and item.kind == :table ->
              %Style{fg: :black, bg: :cyan, modifiers: [:bold]}

            item.active? ->
              %Style{fg: :black, bg: :yellow, modifiers: [:bold]}

            true ->
              %Style{fg: :white, bg: :dark_gray}
          end

        close_style =
          if item.active?,
            do: %Style{fg: :red, bg: style.bg, modifiers: [:bold]},
            else: %Style{fg: :light_red, bg: :dark_gray, modifiers: [:bold]}

        label_len = String.length(item.label)
        close_chars = min(4, label_len)

        main_part =
          if label_len > close_chars,
            do: String.slice(item.label, 0, label_len - close_chars),
            else: ""

        close_part = String.slice(item.label, label_len - close_chars, close_chars)

        line =
          Line.new([
            Span.new(main_part, style: style),
            Span.new(close_part, style: close_style)
          ])

        [
          {%ExRatatui.Widgets.Paragraph{text: [line], style: style}, to_rect(item.rect)}
        ]
      end)

    new_btn_widgets =
      case tb.new_sql_rect do
        %{} = r ->
          [
            {%ExRatatui.Widgets.Paragraph{
               text: " [+ SQL] ",
               style: %Style{fg: :green, modifiers: [:bold]}
             }, to_rect(r)}
          ]

        nil ->
          []
      end

    ai_btn_widgets =
      case tb.ai_sql_rect do
        %{} = r ->
          [
            {%ExRatatui.Widgets.Paragraph{
               text: " [AI] ",
               style: %Style{fg: :magenta, modifiers: [:bold]}
             }, to_rect(r)}
          ]

        nil ->
          []
      end

    [bg_widget] ++ tab_widgets ++ new_btn_widgets ++ ai_btn_widgets
  end

  defp to_rect(%{x: x, y: y, width: w, height: h}) do
    %ExRatatui.Layout.Rect{x: x, y: y, width: w, height: h}
  end

  defp render_header(app, area) do
    if area.height > 0 do
      table_option =
        if Map.get(app, :active_view) == :table_view,
          do: "[★ 1: Table View]",
          else: "[ 1: Table View ]"

      query_option =
        if Map.get(app, :active_view) == :query_view,
          do: "[★ 2: Query View]",
          else: "[ 2: Query View ]"

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

  defp render_editor_with_meta(app, area) do
    if area.height > 0 do
      editor_chunk = SQLEditor.render(app, area)
      fg = if app.focus == :editor, do: :yellow, else: :cyan

      body_rect = to_rect(area)

      active_tab = Map.get(editor_chunk, :active_tab)
      viewport_h = max(1, area.height - 2)
      total_v_lines = length(editor_chunk.lines)
      max_top = max(0, total_v_lines - viewport_h)
      scroll_top = SQLEditor.effective_scroll_top(active_tab, area)

      visible_lines =
        editor_chunk.lines
        |> Enum.drop(scroll_top)
        |> Enum.take(viewport_h)

      editor_focused? = app.focus == :editor and not Map.get(app, :selection_capture?, false)
      diagnostics = Map.get(editor_chunk, :diagnostics, [])
      diags_by_row = Enum.group_by(diagnostics, & &1.line)

      styled_lines =
        Enum.map(visible_lines, fn line_info ->
          row_diags = Map.get(diags_by_row, line_info.logical_row, [])
          build_highlighted_sql_line(line_info, editor_focused?, row_diags)
        end)

      base_editor_title =
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
              if db_name != "" and String.downcase(db_name) != String.downcase(conn_name) and
                   db_name != schema,
                 do: " · #{db_name}",
                 else: ""

            schema_part = if is_binary(schema) and schema != "", do: " · #{schema}", else: ""
            " SQL EDITOR [#{conn_name}#{db_part}#{schema_part}] "

          _ ->
            " SQL EDITOR "
        end

      editor_title =
        case diagnostics do
          [first | _] ->
            badge = if first.severity == :error, do: "✖", else: "⚠"
            raw_msg = to_string(first.message)

            msg =
              if String.length(raw_msg) > 38,
                do: String.slice(raw_msg, 0, 35) <> "...",
                else: raw_msg

            "#{String.trim_trailing(base_editor_title)} · #{badge} L#{first.line + 1}: #{msg} "

          [] ->
            base_editor_title
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
              Enum.map(suggs, &format_completion_item/1)

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

      v_scrollbar =
        if total_v_lines > viewport_h do
          [
            {%ExRatatui.Widgets.Scrollbar{
               orientation: :vertical_right,
               content_length: max(1, max_top),
               position: scroll_top,
               thumb_symbol: "┃",
               track_symbol: "│",
               begin_symbol: "▲",
               end_symbol: "▼",
               thumb_style: %ExRatatui.Style{fg: fg, modifiers: [:bold]},
               track_style: %ExRatatui.Style{fg: :dark_gray}
             }, body_rect}
          ]
        else
          []
        end

      regions = wrapped_region_for_rect(area, visible_lines, editor_chunk.gutter_width)
      {[{paragraph_widget, body_rect}] ++ v_scrollbar ++ completion_items, regions}
    else
      widget = %ExRatatui.Widgets.Paragraph{text: ""}
      {{widget, to_rect(area)}, []}
    end
  end

  @doc """
  Computes the floating SQL Editor autocomplete popup rect when active, or `nil` when hidden.
  Shared between `render_editor_with_meta/2` and `Strata.UI.Selection.bounds_for_anchor/2`.
  """
  @spec editor_completion_rect(map(), rect()) :: rect() | nil
  def editor_completion_rect(app, %{height: h} = area) when h > 0 do
    active_tab = Enum.find(Map.get(app, :tabs, []), &(&1.id == Map.get(app, :active_tab_id)))
    comp = Map.get(active_tab || %{}, :completion, %{})
    suggs = Map.get(comp, :suggestions, [])

    if comp != %{} and Map.get(comp, :active?, false) and suggs != [] do
      content = Map.get(active_tab, :content, "")
      cursor = Map.get(active_tab, :cursor, {0, 0})

      %{code_width: cw, gutter_width: gw} = SQLEditor.editor_metrics(content, area)
      %{cursor_v_pos: {v_row, v_col}} = SQLEditor.visual_layout(content, cursor, cw)
      scroll_top = SQLEditor.effective_scroll_top(active_tab, area)

      max_item_w =
        suggs
        |> Enum.map(&String.length(format_completion_item(&1)))
        |> Enum.max(fn -> 20 end)

      popup_width = min(48, max(24, min(max_item_w + 5, max(20, area.width - 2))))
      popup_height = min(8, length(suggs) + 2)

      px = min(area.x + area.width - popup_width, area.x + v_col + gw)
      py = min(area.y + area.height - popup_height, area.y + max(0, v_row - scroll_top) + 1)

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

  defp format_completion_item(sug) do
    icon =
      case sug.type do
        :keyword -> "K"
        :table -> "⊞"
        :column -> "•"
        _ -> "·"
      end

    detail = Map.get(sug, :detail)

    if is_binary(detail) and detail != "" and detail not in ["keyword", "table"] do
      " #{icon} #{sug.label}  [#{detail}]"
    else
      " #{icon} #{sug.label}"
    end
  end

  defp build_highlighted_sql_line(line_info, editor_focused?, row_diags) do
    alias ExRatatui.Style
    alias ExRatatui.Text.{Line, Span}

    prefix_style =
      cond do
        Enum.any?(row_diags, &(&1.severity == :error)) ->
          %Style{fg: :red, modifiers: [:bold]}

        row_diags != [] ->
          %Style{fg: :yellow, modifiers: [:bold]}

        true ->
          %Style{fg: :dark_gray}
      end

    prefix_span = Span.new(line_info.prefix, style: prefix_style)
    diag_tokens = row_diags |> Enum.map(&Map.get(&1, :token)) |> Enum.reject(&is_nil/1)

    token_spans =
      case Map.get(line_info, :tokens, []) do
        [] ->
          [Span.new(line_info.text)]

        tokens ->
          Enum.map(tokens, fn %{type: type, text: text} ->
            base_style =
              case type do
                :keyword -> %Style{fg: :cyan, modifiers: [:bold]}
                :string -> %Style{fg: :green}
                :number -> %Style{fg: :magenta}
                :comment -> %Style{fg: :dark_gray}
                :operator -> %Style{fg: :yellow}
                _ -> %Style{}
              end

            style =
              if diag_tokens != [] and Enum.any?(diag_tokens, &(&1 == text)) do
                %{
                  base_style
                  | fg: :red,
                    modifiers: Enum.uniq([:underlined | base_style.modifiers])
                }
              else
                base_style
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

        i = %{
          x: body_area.x + body_area.width - insp_w,
          y: body_area.y,
          width: insp_w,
          height: body_area.height
        }

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

    {value_metas, fmt_badge} =
      cached_inspector_value_lines(raw_cell, col_name, r_idx, fmt, max_line_w)

    value_lines = Enum.map(value_metas, & &1.line)
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
      value_line_metas: value_metas,
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

    Strata.UI.Cache.fetch(
      :strata_inspector_sum_cache,
      {columns, row_vals, c_idx, max_line_w},
      64,
      fn ->
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

            clipped_val =
              if String.length(val_str) > avail_val,
                do: String.slice(val_str, 0, avail_val - 1) <> "…",
                else: val_str

            val_style =
              cond do
                active? -> %Style{fg: :yellow, modifiers: [:bold]}
                is_nil(v) -> %Style{fg: :dark_gray}
                is_number(v) -> %Style{fg: :magenta}
                true -> %Style{fg: :white}
              end

            col_style =
              if active?, do: %Style{fg: :yellow, modifiers: [:bold]}, else: %Style{fg: :cyan}

            Line.new([
              Span.new(prefix, style: col_style),
              Span.new(col_str, style: col_style),
              Span.new(clipped_val, style: val_style)
            ])
          end)
        else
          [Line.new([Span.new("(No row selected)", style: %Style{fg: :dark_gray})])]
        end
      end
    )
  end

  defp cached_inspector_value_lines(raw_cell, col_name, r_idx, fmt, max_line_w) do
    Strata.UI.Cache.fetch(:strata_inspector_val_cache, {:v2, raw_cell, fmt, max_line_w}, 64, fn ->
      compute_inspector_value_lines(raw_cell, col_name, r_idx, fmt, max_line_w)
    end)
  end

  defp compute_inspector_value_lines(raw_cell, _col_name, _r_idx, fmt, max_line_w) do
    alias ExRatatui.Style
    alias ExRatatui.Text.{Line, Span}

    {detected_type, formatted_value} = Strata.Formatter.inspect_cell_value(raw_cell)

    cond do
      fmt == :raw ->
        {Strata.Formatter.wrap_text_lines_with_meta(inspect(raw_cell, pretty: true), max_line_w),
         "raw"}

      fmt == :text ->
        {Strata.Formatter.wrap_text_lines_with_meta(
           Strata.Formatter.format_cell_detail(raw_cell),
           max_line_w
         ), "text"}

      detected_type == :json ->
        {Strata.Formatter.highlight_json_lines_with_meta(formatted_value, max_line_w), "JSON"}

      detected_type == nil ->
        {[
           %{
             line:
               Line.new([Span.new("<NULL>", style: %Style{fg: :dark_gray, modifiers: [:bold]})]),
             continued?: false,
             text: "<NULL>"
           }
         ], "NULL"}

      detected_type == :uuid ->
        {Strata.Formatter.wrap_text_lines_with_meta(
           formatted_value,
           max_line_w,
           %Style{fg: :cyan}
         ), "UUID"}

      true ->
        {Strata.Formatter.wrap_text_lines_with_meta(
           formatted_value,
           max_line_w,
           %Style{fg: :white}
         ), to_string(detected_type)}
    end
  end

  defp render_datagrid_with_meta(app, total_area) do
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
            do:
              "TABLE: #{tbl} (#{row_count_label} - #{more_status})#{sort_badge}#{filter_badge}#{dirty_badge}#{loading_badge}#{mode_badge}",
            else: "TABLE VIEW#{loading_badge}#{mode_badge}"

        :query_view ->
          more_part = if grid.has_more or grid.loading_more, do: " - #{more_status}", else: ""

          "QUERY RESULT GRID (#{row_count_label}#{more_part})#{sort_badge}#{dirty_badge}#{loading_badge}#{mode_badge}"

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
      if grid.mode == :selecting and string_rows != [] and local_row_idx >= 0 and
           local_row_idx < length(string_rows) do
        local_row_idx
      else
        nil
      end

    selected_col =
      if grid.mode == :selecting and visible_columns != [] and local_col_idx >= 0 and
           local_col_idx < length(visible_columns) do
        local_col_idx
      else
        nil
      end

    has_left_cols? = col_offset > 0
    has_right_cols? = col_offset + visible_col_count < length(grid.columns)

    scroll_indicator =
      cond do
        has_left_cols? and has_right_cols? ->
          " [◀ Cols #{col_offset + 1}-#{col_offset + visible_col_count}/#{length(grid.columns)} ▶]"

        has_left_cols? ->
          " [◀ Cols #{col_offset + 1}-#{col_offset + visible_col_count}/#{length(grid.columns)}]"

        has_right_cols? ->
          " [Cols 1-#{visible_col_count}/#{length(grid.columns)} ▶]"

        true ->
          ""
      end

    title_with_indicator = title <> scroll_indicator

    highlight_sym = ""

    highlight_st =
      if grid.mode == :selecting,
        do: %ExRatatui.Style{fg: :black, bg: :yellow},
        else: %ExRatatui.Style{}

    cell_highlight_st =
      if grid.mode == :selecting,
        do: %ExRatatui.Style{fg: :white, bg: :green, modifiers: [:bold]},
        else: %ExRatatui.Style{}

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

    {inspector_widgets, inspector_regions} =
      render_inspector_drawer_with_meta(app, grid, inspector_area)

    dropdown_widgets = render_filter_dropdown(app, total_area)

    widgets =
      filter_widgets ++
        [{widget, rect}] ++
        v_scrollbar ++
        h_scrollbar ++
        throbber_overlay ++
        inline_overlay ++
        inspector_widgets ++
        dropdown_widgets

    rendered =
      case widgets do
        [single] -> single
        list -> list
      end

    {rendered, inspector_regions}
  end

  @doc """
  Computes the floating dropdown geometry and items for the Unified Filter & Sort Bar
  (`:column`, `:op`, or `:sort`), returning `nil` when closed. Shared with mouse click handling in `App`.
  """
  @spec filter_dropdown_data(map(), rect()) :: map() | nil
  def filter_dropdown_data(app, total_area) do
    kind = Map.get(app, :filter_dropdown)
    filter_open? = Map.get(app, :filter_bar_open, false)

    if kind in [:column, :op, :sort] and filter_open? do
      %{filter_area: f_area} = datagrid_areas(total_area, app)

      if f_area do
        rects = filter_bar_rects(f_area, app)

        anchor =
          case kind do
            :column -> rects.col_rect
            :op -> rects.op_rect
            :sort -> rects.sort_rect
          end

        grid = Map.get(app, :datagrid_state) || DataGrid.new()

        search =
          String.downcase(String.trim(to_string(Map.get(app, :filter_dropdown_search, ""))))

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

            :sort ->
              col_items =
                (grid.columns || [])
                |> Enum.with_index()
                |> Enum.map(fn {col_name, col_idx} ->
                  name_str = to_string(col_name)

                  dir_suffix =
                    case grid.sort_by do
                      {^name_str, :asc} -> "  ▲ (ASC)"
                      {^name_str, :desc} -> "  ▼ (DESC)"
                      _ -> ""
                    end

                  %{
                    kind: :column,
                    col_idx: col_idx,
                    name: name_str,
                    label: name_str <> dir_suffix
                  }
                end)
                |> Enum.filter(fn item ->
                  search == "" or String.contains?(String.downcase(item.name), search)
                end)
                |> Enum.sort_by(fn item ->
                  low = String.downcase(item.name)
                  if search != "" and String.starts_with?(low, search), do: 0, else: 1
                end)

              if grid.sort_by != nil and search == "" do
                col_items ++ [%{kind: :clear, col_idx: nil, name: "", label: "✕ Clear Sort"}]
              else
                col_items
              end
          end

        box_w =
          case kind do
            :op -> 26
            _ -> 32
          end

        max_w = max(18, total_area.width - 2)
        w = min(box_w, max_w)
        x = min(anchor.x, max(total_area.x, total_area.x + total_area.width - w - 1))
        y = f_area.y + 3
        max_h = max(4, total_area.y + total_area.height - y)
        h = min(min(13, max_h), max(3, length(items) + 2))

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
            :sort when search != "" -> " ↕ Sort: #{search}▏ "
            :sort -> " ↕ Sort by Column (Enter/Esc) "
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

  defp sort_pill_text(app) do
    grid = Map.get(app, :datagrid_state)

    case grid && Map.get(grid, :sort_by) do
      {col, dir} ->
        arrow = if dir == :asc, do: "▲", else: "▼"
        short_col = truncate_label(to_string(col), 12)
        " ↕ #{short_col} #{arrow} ▾ "

      _ ->
        " ↕ Sort ▾ "
    end
  end

  defp truncate_label(str, max_len) do
    if String.length(str) > max_len do
      String.slice(str, 0, max(1, max_len - 1)) <> "…"
    else
      str
    end
  end

  @doc """
  Computes sub-widget rectangles inside the Unified Filter & Sort Bar for both rendering and mouse clicks.
  """
  @spec filter_bar_rects(rect(), map()) :: map()
  def filter_bar_rects(f_area, app) do
    inner_x = f_area.x + 1
    inner_y = f_area.y + 1
    clear_w = 3
    run_w = 5

    right_edge = f_area.x + f_area.width - 1
    clear_x = max(inner_x + 12, right_edge - clear_w)
    run_x = max(inner_x + 6, clear_x - 1 - run_w)

    sort_text = sort_pill_text(app)
    sort_w = min(max(10, div(f_area.width, 4)), max(10, String.length(sort_text)))
    sort_x = max(inner_x + 6, run_x - 1 - sort_w)

    clear_rect = %{x: clear_x, y: inner_y, width: clear_w, height: 1}
    run_rect = %{x: run_x, y: inner_y, width: run_w, height: 1}
    sort_rect = %{x: sort_x, y: inner_y, width: sort_w, height: 1}

    avail = max(6, sort_x - inner_x - 1)
    col_str = Map.get(app, :filter_bar_col, "* All") || "* All"
    op = Map.get(app, :filter_bar_op, :contains) || :contains
    op_label = Strata.QueryBuilder.operator_label(op)

    col_text = " #{col_str} ▾ "
    op_text = " #{op_label} ▾ "

    col_w = min(max(10, div(avail, 3)), max(9, String.length(col_text)))
    op_w = min(max(8, div(avail, 4) + 2), max(6, String.length(op_text)))
    val_x = inner_x + col_w + 1 + op_w + 1
    val_w = max(4, sort_x - val_x - 1)

    %{
      col_rect: %{x: inner_x, y: inner_y, width: col_w, height: 1},
      op_rect: %{x: inner_x + col_w + 1, y: inner_y, width: op_w, height: 1},
      val_rect: %{x: val_x, y: inner_y, width: val_w, height: 1},
      sort_rect: sort_rect,
      run_rect: run_rect,
      clear_rect: clear_rect
    }
  end

  defp render_inline_filter_bar(_app, nil), do: []

  defp render_inline_filter_bar(app, f_area) do
    focused? = Map.get(app, :filter_bar_focused, false)
    focus_part = Map.get(app, :filter_bar_focus_part, :value)
    border_fg = if focused?, do: :yellow, else: :cyan

    title =
      if focused? do
        " 🔍 Filter & Sort (Enter/[Run] Apply · ↑ History · Tab Col/Op/Sort · Ctrl+G SQL Tab · Ctrl+L Reset) "
      else
        " 🔍 Active Filter & Sort ([f] Edit · [o] Sort · [Ctrl+G] SQL Tab · [Ctrl+L] Reset · [Esc] Hide) "
      end

    f_rect = to_rect(f_area)

    outer_block = %ExRatatui.Widgets.Block{
      title: title,
      borders: [:all],
      border_type: :rounded,
      border_style: %ExRatatui.Style{fg: border_fg}
    }

    rects = filter_bar_rects(f_area, app)

    sort_style =
      cond do
        focused? and focus_part == :sort ->
          %ExRatatui.Style{fg: :black, bg: :yellow, modifiers: [:bold]}

        get_in(app, [Access.key(:datagrid_state), Access.key(:sort_by)]) != nil ->
          %ExRatatui.Style{fg: :black, bg: :cyan, modifiers: [:bold]}

        true ->
          %ExRatatui.Style{fg: :white, bg: :dark_gray, modifiers: [:bold]}
      end

    action_widgets = [
      {%ExRatatui.Widgets.Paragraph{text: sort_pill_text(app), style: sort_style},
       to_rect(rects.sort_rect)},
      {%ExRatatui.Widgets.Paragraph{
         text: "[Run]",
         style: %ExRatatui.Style{fg: :black, bg: :green, modifiers: [:bold]}
       }, to_rect(rects.run_rect)},
      {%ExRatatui.Widgets.Paragraph{
         text: "[×]",
         style: %ExRatatui.Style{fg: :white, bg: :red, modifiers: [:bold]}
       }, to_rect(rects.clear_rect)}
    ]

    value_widgets = render_filter_value_widget(app, rects.val_rect, focused?, focus_part)

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

    left_widgets = [
      {%ExRatatui.Widgets.Paragraph{text: " #{col_str} ▾ ", style: col_style},
       to_rect(rects.col_rect)},
      {%ExRatatui.Widgets.Paragraph{text: " #{op_label} ▾ ", style: op_style},
       to_rect(rects.op_rect)}
    ]

    [{outer_block, f_rect}] ++ left_widgets ++ value_widgets ++ action_widgets
  end

  defp render_filter_value_widget(app, v_rect, focused?, focus_part) do
    op = Map.get(app, :filter_bar_op, :contains)
    no_val_needed? = op in [:is_null, :is_not_null]
    rect = to_rect(v_rect)

    cond do
      no_val_needed? ->
        [
          {%ExRatatui.Widgets.Paragraph{
             text: "(no value needed — Enter to apply)",
             style: %ExRatatui.Style{fg: :dark_gray}
           }, rect}
        ]

      focused? and focus_part == :value and not is_nil(Map.get(app, :filter_bar_ref)) ->
        [
          {%ExRatatui.Widgets.TextInput{
             state: app.filter_bar_ref,
             style: %ExRatatui.Style{fg: :white, bg: :dark_gray},
             cursor_style: %ExRatatui.Style{fg: :black, bg: :yellow, modifiers: [:bold]}
           }, rect}
        ]

      true ->
        raw_txt = Map.get(app, :filter_bar_text, "")
        txt = if raw_txt == "", do: "type value to filter...", else: raw_txt

        style =
          if raw_txt == "",
            do: %ExRatatui.Style{fg: :dark_gray},
            else: %ExRatatui.Style{fg: :white}

        [{%ExRatatui.Widgets.Paragraph{text: txt, style: style}, rect}]
    end
  end

  defp render_inspector_drawer_with_meta(_app, _grid, nil), do: {[], []}

  defp render_inspector_drawer_with_meta(app, grid, i_area) do
    data = inspector_data(app, grid, i_area)
    v_area = data.areas.value_area
    s_area = data.areas.summary_area

    v_scroll = min(Map.get(app, :inspector_value_scroll, 0) || 0, data.max_value_scroll)

    v_visible_metas =
      data.value_line_metas |> Enum.drop(v_scroll) |> Enum.take(data.val_viewport_h)

    v_visible = Enum.map(v_visible_metas, & &1.line)

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

    regions = wrapped_region_for_rect(v_area, v_visible_metas)
    {[{value_widget, v_rect}] ++ value_scrollbar ++ summary_widgets, regions}
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

        match?(%Strata.UI.Components.SQLTabPickerModal{}, top) ->
          item_cnt = length(Strata.UI.Components.SQLTabPickerModal.visible_items(top))
          {80, max(10, min(22, item_cnt + 4))}

        match?(%Strata.UI.Components.ExportModal{}, top) ->
          {74, 18}

        match?(%Strata.UI.Components.ConnectionModal{}, top) ->
          {72, 22}

        match?(%Strata.UI.Components.SSHModal{}, top) ->
          {72, 22}

        match?(%Strata.UI.Components.AISettingsModal{}, top) ->
          {74, 18}

        match?(%{type: :confirm_delete_connection}, top) ->
          {54, 9}

        true ->
          {64, 18}
      end

    modal_layout(window_size, dims)
  end

  def modal_area_for(_app, window_size), do: modal_layout(window_size, {64, 18})

  defp render_modal_with_meta(app, window_size) do
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

        {[{clear_widget, m_rect}, {list_widget, m_rect}], []}

      [%Strata.UI.Components.SQLTabPickerModal{} = picker | _] ->
        modal_area = modal_area_for(app, window_size)
        m_rect = to_rect(modal_area)
        clear_widget = %ExRatatui.Widgets.Clear{}
        items = Strata.UI.Components.SQLTabPickerModal.visible_items(picker)
        list_items = Enum.map(items, & &1.label)
        sel_idx = min(picker.selected_index, max(0, length(list_items) - 1))

        filter_part =
          if String.trim(picker.filter || "") != "",
            do: " [Filter: #{picker.filter}]",
            else: ""

        title =
          " ✨ SQL Tabs#{filter_part} (↑/↓ · Enter Open · Ctrl+D Remove · Type Search · Esc) "

        list_widget = %ExRatatui.Widgets.List{
          items: list_items,
          selected: sel_idx,
          highlight_symbol: "▸ ",
          highlight_style: %ExRatatui.Style{fg: :black, bg: :yellow, modifiers: [:bold]},
          block: %ExRatatui.Widgets.Block{
            title: title,
            borders: [:all],
            border_type: :rounded,
            border_style: %ExRatatui.Style{fg: :cyan}
          }
        }

        {[{clear_widget, m_rect}, {list_widget, m_rect}], []}

      [top | _] ->
        modal_area = modal_area_for(app, window_size)
        m_rect = to_rect(modal_area)

        rendered_info =
          case top do
            %Strata.UI.Components.ConnectionModal{} = conn_modal ->
              Strata.UI.Components.ConnectionModal.render(conn_modal, modal_area)

            %Strata.UI.Components.ExportModal{} = export_modal ->
              Strata.UI.Components.ExportModal.render(export_modal, modal_area)

            %Strata.UI.Components.SSHModal{} = ssh_modal ->
              Strata.UI.Components.SSHModal.render(ssh_modal, modal_area)

            %Strata.UI.Components.AISettingsModal{} = ai_settings_modal ->
              Strata.UI.Components.AISettingsModal.render(ai_settings_modal, modal_area)

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

        {content_lines, modal_regions} =
          case Map.get(rendered_info, :fields) do
            fields when is_list(fields) ->
              lines =
                Enum.map(fields, fn f ->
                  focused? = f.key == focused
                  prefix = if focused?, do: " ▸ ", else: "   "

                  cond do
                    Map.has_key?(f, :value) ->
                      label = String.pad_trailing(to_string(f.label), 17)
                      val = to_string(f.value || "")

                      if focused? do
                        Line.new([
                          Span.new(prefix <> label <> ": ",
                            style: %Style{fg: :yellow, modifiers: [:bold]}
                          ),
                          Span.new(val,
                            style: %Style{fg: :black, bg: :yellow, modifiers: [:bold]}
                          )
                        ])
                      else
                        Line.new([
                          Span.new(prefix <> label <> ": ", style: %Style{fg: :cyan}),
                          Span.new(val, style: %Style{fg: :white})
                        ])
                      end

                    focused? ->
                      Line.new([
                        Span.new(prefix <> to_string(f.label),
                          style: %Style{fg: :black, bg: :yellow, modifiers: [:bold]}
                        )
                      ])

                    true ->
                      btn_fg =
                        if String.contains?(to_string(f.label), "Delete"), do: :red, else: :white

                      Line.new([
                        Span.new(prefix <> to_string(f.label),
                          style: %Style{fg: btn_fg, modifiers: [:bold]}
                        )
                      ])
                  end
                end)

              {lines, []}

            _ ->
              raw_content =
                case Map.get(rendered_info, :content) do
                  content when is_binary(content) -> content
                  other -> to_string(other || inspect(top))
                end

              {body_text, hint_metas} =
                case String.split(raw_content, "\n─────", parts: 2) do
                  [body, hint] ->
                    hint_line =
                      Line.new([Span.new("─────" <> hint, style: %Style{fg: :dark_gray})])

                    {body, [%{line: hint_line, continued?: false, text: "─────" <> hint}]}

                  _ ->
                    {raw_content, []}
                end

              max_mw = max(12, modal_area.width - 4)

              line_metas =
                cond do
                  match?(%{format: :json}, rendered_info) ->
                    Strata.Formatter.highlight_json_lines_with_meta(body_text, max_mw) ++
                      hint_metas

                  Map.get(rendered_info, :wrap_lines, false) ->
                    Strata.Formatter.wrap_text_lines_with_meta(body_text, max_mw) ++ hint_metas

                  true ->
                    raw_content
                    |> String.split("\n")
                    |> Enum.map(fn ln ->
                      %{line: Line.new([Span.new(ln)]), continued?: false, text: ln}
                    end)
                end

              {Enum.map(line_metas, & &1.line), wrapped_region_for_rect(modal_area, line_metas)}
          end

        status_lines =
          case Map.get(rendered_info, :status_message) do
            msg when is_binary(msg) and msg != "" ->
              st =
                cond do
                  String.contains?(msg, ["❌", "failed", "Error"]) ->
                    %Style{fg: :red, modifiers: [:bold]}

                  String.contains?(msg, ["⏳", "Testing"]) ->
                    %Style{fg: :yellow, modifiers: [:bold]}

                  true ->
                    %Style{fg: :green, modifiers: [:bold]}
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

        {[{clear_widget, m_rect}, {modal_widget, m_rect}], modal_regions}

      [] ->
        {[], []}
    end
  end

  defp wrapped_region_for_rect(rect, visible_metas, x_offset \\ 0) do
    inner_w = max(0, rect.width - 2)
    inner_h = max(0, rect.height - 2)

    if inner_w > 0 and inner_h > 0 do
      min_x = rect.x + 1 + x_offset
      max_x = rect.x + rect.width - 2
      min_y = rect.y + 1
      max_y = rect.y + rect.height - 2

      if min_x <= max_x do
        rows =
          visible_metas
          |> Enum.take(inner_h)
          |> Enum.with_index()
          |> Map.new(fn {meta, idx} ->
            {min_y + idx,
             %{continued?: Map.get(meta, :continued?, false), text: Map.get(meta, :text, "")}}
          end)

        [%{bounds: %{min_x: min_x, max_x: max_x, min_y: min_y, max_y: max_y}, rows: rows}]
      else
        []
      end
    else
      []
    end
  end
end
