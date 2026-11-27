defmodule Strata.UI.Components.AIChatPanel do
  @moduledoc """
  Right-hand AI SQL Assistant drawer panel (analogous to the DataGrid Inspector Drawer).
  Displays the active SQL tab's multi-turn conversation & SQL result cards on top
  (allowing re-selection and re-application of any prior turn) and a chat input box below.
  """

  alias ExRatatui.Style
  alias ExRatatui.Text.{Line, Span}
  alias ExRatatui.Widgets.{Block, Paragraph, Scrollbar}

  @long_paste_min_lines 3
  @long_paste_min_chars 120

  @doc """
  Returns true when pasted text is multi-line (`>= 3` lines) or exceeds `120` characters
  and should be collapsed into an inline `[Pasted #N ...]` chip.
  """
  @spec long_paste?(String.t()) :: boolean()
  def long_paste?(text) when is_binary(text) do
    line_count = text |> String.split("\n") |> length()
    line_count >= @long_paste_min_lines or String.length(text) > @long_paste_min_chars
  end

  @doc """
  Formats a compact inline chip label for a collapsed paste block.
  """
  @spec paste_pill_label(pos_integer(), String.t()) :: String.t()
  def paste_pill_label(seq, text) when is_integer(seq) and is_binary(text) do
    line_count = text |> String.split("\n") |> length()

    if line_count > 1 do
      "[Pasted ##{seq} +#{line_count - 1} lines]"
    else
      "[Pasted ##{seq} · #{String.length(text)} chars]"
    end
  end

  @doc """
  Expands any collapsed paste chip tokens in `text` back to their full pasted payloads.
  """
  @spec expand_pastes(String.t(), map()) :: String.t()
  def expand_pastes(text, pastes) when is_binary(text) and is_map(pastes) do
    if map_size(pastes) == 0 do
      text
    else
      Enum.reduce(pastes, text, fn {token, full_text}, acc ->
        String.replace(acc, token, full_text)
      end)
    end
  end

  def expand_pastes(text, _), do: to_string(text || "")

  @doc """
  Atomically deletes either an entire paste token ending at `pos` or a single grapheme before `pos`.
  """
  @spec delete_before_cursor(String.t(), non_neg_integer(), map()) ::
          {String.t(), non_neg_integer(), map()}
  def delete_before_cursor(text, pos, pastes) do
    case find_token_ending_at(text, pos, pastes) do
      {token, start_pos} ->
        new_text = String.slice(text, 0, start_pos) <> String.slice(text, pos..-1//1)
        new_pastes = maybe_drop_unused_paste(new_text, token, pastes)
        {new_text, start_pos, new_pastes}

      nil ->
        if pos > 0 do
          new_text = String.slice(text, 0, pos - 1) <> String.slice(text, pos..-1//1)
          {new_text, pos - 1, pastes}
        else
          {text, pos, pastes}
        end
    end
  end

  @doc """
  Atomically deletes either an entire paste token starting at `pos` or a single grapheme at `pos`.
  """
  @spec delete_at_cursor(String.t(), non_neg_integer(), map()) ::
          {String.t(), non_neg_integer(), map()}
  def delete_at_cursor(text, pos, pastes) do
    case find_token_starting_at(text, pos, pastes) do
      {token, end_pos} ->
        new_text = String.slice(text, 0, pos) <> String.slice(text, end_pos..-1//1)
        new_pastes = maybe_drop_unused_paste(new_text, token, pastes)
        {new_text, pos, new_pastes}

      nil ->
        if pos < String.length(text) do
          new_text = String.slice(text, 0, pos) <> String.slice(text, (pos + 1)..-1//1)
          {new_text, pos, pastes}
        else
          {text, pos, pastes}
        end
    end
  end

  @doc """
  Moves cursor left by one grapheme or jumps cleanly over an adjacent paste token.
  """
  @spec move_cursor_left(String.t(), non_neg_integer(), map()) :: non_neg_integer()
  def move_cursor_left(text, pos, pastes) do
    case find_token_ending_at(text, pos, pastes) do
      {_token, start_pos} -> start_pos
      nil -> max(0, pos - 1)
    end
  end

  @doc """
  Moves cursor right by one grapheme or jumps cleanly over an adjacent paste token.
  """
  @spec move_cursor_right(String.t(), non_neg_integer(), map()) :: non_neg_integer()
  def move_cursor_right(text, pos, pastes) do
    case find_token_starting_at(text, pos, pastes) do
      {_token, end_pos} -> end_pos
      nil -> min(String.length(text), pos + 1)
    end
  end

  defp find_token_ending_at(text, pos, pastes) when is_map(pastes) and map_size(pastes) > 0 do
    prefix = String.slice(text, 0, pos)

    Enum.find_value(Map.keys(pastes), fn token ->
      if String.ends_with?(prefix, token) do
        {token, pos - String.length(token)}
      end
    end)
  end

  defp find_token_ending_at(_text, _pos, _pastes), do: nil

  defp find_token_starting_at(text, pos, pastes) when is_map(pastes) and map_size(pastes) > 0 do
    suffix = String.slice(text, pos..-1//1)

    Enum.find_value(Map.keys(pastes), fn token ->
      if String.starts_with?(suffix, token) do
        {token, pos + String.length(token)}
      end
    end)
  end

  defp find_token_starting_at(_text, _pos, _pastes), do: nil

  defp maybe_drop_unused_paste(text, token, pastes) do
    if String.contains?(text, token), do: pastes, else: Map.delete(pastes, token)
  end

  @doc """
  Splits `ai_area` vertically into `{history_area, input_area}`.
  Default `input_area` is a compact 3-row box (border + input + border) and expands
  dynamically up to 5 rows when `input_text` spans multiple lines.
  """
  @spec areas(map() | nil, keyword()) :: %{history_area: map(), input_area: map() | nil} | nil
  def areas(ai_area, opts \\ [])
  def areas(nil, _opts), do: nil

  def areas(%{x: x, y: y, width: w, height: h}, opts) do
    if h >= 7 do
      input_text = to_string(Keyword.get(opts, :input_text, "") || "")
      line_count = input_text |> String.split("\n") |> length()
      desired_input_h = if line_count > 1, do: min(5, 2 + line_count), else: 3
      max_input_h = max(3, min(5, div(h, 2)))
      input_h = min(desired_input_h, max_input_h)
      history_h = max(4, h - input_h)

      %{
        history_area: %{x: x, y: y, width: w, height: history_h},
        input_area: %{x: x, y: y + history_h, width: w, height: h - history_h}
      }
    else
      %{
        history_area: %{x: x, y: y, width: w, height: h},
        input_area: nil
      }
    end
  end

  @doc """
  Computes the text rect inside `input_area`.
  """
  @spec input_rects(map() | nil) :: map() | nil
  def input_rects(nil), do: nil

  def input_rects(%{x: x, y: y, width: w, height: h}) do
    %{
      text_rect: %{x: x + 1, y: y + 1, width: max(4, w - 2), height: max(1, h - 2)}
    }
  end

  @doc """
  Builds rendered history lines, per-turn line ranges `{start_line, end_line}`, and scroll bounds.
  Shared between rendering and mouse click/scroll handling.
  """
  @spec history_data(map(), map() | nil, map()) :: map()
  def history_data(app, tab, history_area) do
    messages = (tab && Map.get(tab, :ai_messages, [])) || []
    applied_id = tab && Map.get(tab, :ai_applied_msg_id)
    inner_w = max(10, history_area.width - 3)
    viewport_h = max(1, history_area.height - 2)

    selected_idx =
      case Map.get(app, :ai_selected_msg_idx) do
        idx when is_integer(idx) and messages != [] ->
          max(0, min(length(messages) - 1, idx))

        _ when messages != [] ->
          length(messages) - 1

        _ ->
          nil
      end

    {rev_lines, rev_ranges, total_lines} =
      if messages == [] do
        empty = [
          Line.new([
            Span.new("Ask AI to generate or refine SQL.", style: %Style{fg: :dark_gray})
          ]),
          Line.new([
            Span.new("Schema of your active table &", style: %Style{fg: :dark_gray})
          ]),
          Line.new([
            Span.new("FK tables is included automatically.", style: %Style{fg: :dark_gray})
          ]),
          Line.new([]),
          Line.new([
            Span.new("Tips:", style: %Style{fg: :cyan, modifiers: [:bold]})
          ]),
          Line.new([
            Span.new("• Enter in Ask box sends request", style: %Style{fg: :gray})
          ]),
          Line.new([
            Span.new("• ↑ jumps to past AI turns", style: %Style{fg: :gray})
          ]),
          Line.new([
            Span.new("• Enter/Click turn re-applies SQL", style: %Style{fg: :gray})
          ])
        ]

        {Enum.reverse(empty), [], length(empty)}
      else
        messages
        |> Enum.with_index()
        |> Enum.reduce({[], [], 0}, fn {msg, idx}, {acc_lines, acc_ranges, line_cursor} ->
          selected? = idx == selected_idx and Map.get(app, :ai_panel_focus) == :history
          applied? = is_binary(applied_id) and Map.get(msg, :id) == applied_id
          last? = idx == length(messages) - 1

          turn_lines =
            build_turn_lines(msg, idx + 1, inner_w, selected?, applied?, not last?)

          cnt = length(turn_lines)
          range = {idx, line_cursor, line_cursor + cnt - 1}
          {Enum.reverse(turn_lines) ++ acc_lines, [range | acc_ranges], line_cursor + cnt}
        end)
      end

    lines = Enum.reverse(rev_lines)
    turn_ranges = Enum.reverse(rev_ranges)
    max_scroll = max(0, total_lines - viewport_h)
    raw_scroll = Map.get(app, :ai_history_scroll, max_scroll)
    scroll_top = max(0, min(raw_scroll, max_scroll))

    %{
      lines: lines,
      turn_ranges: turn_ranges,
      selected_idx: selected_idx,
      total_lines: total_lines,
      viewport_h: viewport_h,
      max_scroll: max_scroll,
      scroll_top: scroll_top
    }
  end

  @doc """
  Computes the adjusted scroll offset so the selected turn `idx` stays visible inside `viewport_h`.
  """
  @spec scroll_for_selected_turn(
          [tuple()],
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer()
        ) ::
          non_neg_integer()
  def scroll_for_selected_turn(turn_ranges, idx, current_scroll, viewport_h) do
    case Enum.find(turn_ranges, fn {i, _s, _e} -> i == idx end) do
      {_i, start_ln, end_ln} ->
        cond do
          start_ln < current_scroll ->
            start_ln

          end_ln >= current_scroll + viewport_h ->
            max(0, end_ln - viewport_h + 1)

          true ->
            current_scroll
        end

      nil ->
        current_scroll
    end
  end

  @doc """
  Renders `{widget, rect}` tuples for the Right AI Chat Panel (`history_area` + `input_area`).
  """
  @spec render(map(), map(), map()) :: [{term(), map()}]
  def render(app, tab, ai_area) do
    %{history_area: hist_area, input_area: inp_area} =
      areas(ai_area, input_text: Map.get(app, :ai_input_text, ""))

    panel_focused? = Map.get(app, :focus) == :ai_panel
    sub_focus = Map.get(app, :ai_panel_focus, :input)
    tab_name = (tab && Map.get(tab, :name)) || "SQL"
    messages = (tab && Map.get(tab, :ai_messages, [])) || []

    hist_data = history_data(app, tab, hist_area)
    visible_lines = Enum.slice(hist_data.lines, hist_data.scroll_top, hist_data.viewport_h)

    hist_border_fg =
      if panel_focused? and sub_focus == :history, do: :yellow, else: :magenta

    count_badge = if messages != [], do: " (#{length(messages)})", else: ""

    hist_title =
      if panel_focused? and sub_focus == :history do
        " ✨ AI CHAT · #{tab_name}#{count_badge} [↑/↓ Pick · Enter Apply] "
      else
        " ✨ AI CHAT · #{tab_name}#{count_badge} "
      end

    hist_rect = to_rect(hist_area)

    hist_widget =
      {%Paragraph{
         text: visible_lines,
         block: %Block{
           title: hist_title,
           borders: [:all],
           border_type: :rounded,
           border_style: %Style{fg: hist_border_fg}
         }
       }, hist_rect}

    hist_scrollbar =
      if hist_data.total_lines > hist_data.viewport_h do
        [
          {%Scrollbar{
             orientation: :vertical_right,
             content_length: hist_data.max_scroll,
             position: hist_data.scroll_top,
             thumb_symbol: "┃",
             track_symbol: "│",
             begin_symbol: "▲",
             end_symbol: "▼",
             thumb_style: %Style{fg: :magenta, modifiers: [:bold]},
             track_style: %Style{fg: :dark_gray}
           }, hist_rect}
        ]
      else
        []
      end

    input_widgets = render_input_area(app, tab, inp_area, panel_focused? and sub_focus == :input)

    [hist_widget] ++ hist_scrollbar ++ input_widgets
  end

  defp render_input_area(_app, _tab, nil, _focused?), do: []

  defp render_input_area(app, tab, inp_area, focused?) do
    has_error? =
      is_binary(tab && Map.get(tab, :last_query_error)) and
        String.trim(tab.last_query_error) != ""

    rects = input_rects(inp_area)
    running? = Map.get(app, :ai_request) != nil
    raw_input = Map.get(app, :ai_input_text, "") || ""
    cursor_pos = Map.get(app, :ai_input_cursor, String.length(raw_input))

    border_fg = if focused?, do: :yellow, else: :cyan

    title =
      cond do
        running? -> " ⏳ Thinking... (Esc Cancel) "
        focused? and has_error? -> " 💬 Ask AI (Enter Send · Ctrl+F Fix Err) "
        focused? -> " 💬 Ask AI (Enter Send · Shift+Enter ↵) "
        true -> " 💬 Ask AI (Ctrl+O Focus) "
      end

    outer_block =
      {%Block{
         title: title,
         borders: [:all],
         border_type: :rounded,
         border_style: %Style{fg: border_fg}
       }, to_rect(inp_area)}

    text_lines =
      build_input_lines(
        raw_input,
        cursor_pos,
        rects.text_rect.width,
        rects.text_rect.height,
        focused?,
        running?,
        Map.get(app, :ai_pastes, %{})
      )

    text_widget =
      {%Paragraph{
         text: text_lines
       }, to_rect(rects.text_rect)}

    [outer_block, text_widget]
  end

  defp build_input_lines(_text, _cursor, _w, _h, _focused?, true, _pastes) do
    [Line.new([Span.new("⏳ Waiting for AI CLI response...", style: %Style{fg: :yellow})])]
  end

  defp build_input_lines("", _cursor, _w, _h, true, false, _pastes) do
    [
      Line.new([
        Span.new("▏", style: %Style{fg: :black, bg: :yellow, modifiers: [:bold]}),
        Span.new("Describe SQL or follow-up...", style: %Style{fg: :dark_gray})
      ])
    ]
  end

  defp build_input_lines("", _cursor, _w, _h, false, false, _pastes) do
    [Line.new([Span.new("Describe SQL or follow-up...", style: %Style{fg: :dark_gray})])]
  end

  defp build_input_lines(text, cursor, width, height, focused?, false, pastes) do
    w = max(4, width)
    len = String.length(text)
    pos = max(0, min(cursor || len, len))

    display =
      if focused? do
        String.slice(text, 0, pos) <> "▏" <> String.slice(text, pos..-1//1)
      else
        text
      end

    wrapped = wrap_text(display, w)
    visible = Enum.take(wrapped, -max(1, height))

    Enum.map(visible, fn ln ->
      style_input_line(ln, pastes)
    end)
  end

  defp style_input_line(line_str, pastes) do
    if map_size(pastes || %{}) == 0 do
      Line.new([Span.new(line_str, style: %Style{fg: :white})])
    else
      parts =
        Regex.split(~r/(\[Pasted #\d+[^\]]*\])/, line_str, include_captures: true, trim: true)

      spans =
        Enum.map(parts, fn part ->
          clean_part = String.replace(part, "▏", "")

          if Map.has_key?(pastes, clean_part) do
            Span.new(part, style: %Style{fg: :black, bg: :cyan, modifiers: [:bold]})
          else
            Span.new(part, style: %Style{fg: :white})
          end
        end)

      Line.new(if(spans == [], do: [Span.new("", style: %Style{fg: :white})], else: spans))
    end
  end

  defp build_turn_lines(msg, num, width, selected?, applied?, divider?) do
    prefix = if selected?, do: "▸ ", else: "  "

    tag_style =
      if selected?,
        do: %Style{fg: :black, bg: :yellow, modifiers: [:bold]},
        else: %Style{fg: :cyan, modifiers: [:bold]}

    prompt_text = to_string(Map.get(msg, :prompt, ""))
    prompt_lines = wrap_text(prompt_text, max(6, width - 5))

    first_prompt =
      Line.new([
        Span.new("#{prefix}##{num} ", style: tag_style),
        Span.new(List.first(prompt_lines) || "", style: %Style{fg: :white, modifiers: [:bold]})
      ])

    rest_prompt =
      prompt_lines
      |> Enum.drop(1)
      |> Enum.map(fn ln ->
        Line.new([Span.new("     " <> ln, style: %Style{fg: :white})])
      end)

    body_lines =
      case Map.get(msg, :status, :done) do
        :running ->
          [Line.new([Span.new("  ⏳ Generating SQL...", style: %Style{fg: :yellow})])]

        :error ->
          err = to_string(Map.get(msg, :error) || "Failed")

          wrap_text("❌ " <> err, max(6, width - 2))
          |> Enum.map(fn ln ->
            Line.new([Span.new("  " <> ln, style: %Style{fg: :red})])
          end)

        :done ->
          badge_span =
            cond do
              applied? ->
                Span.new(" ★ Applied ", style: %Style{fg: :black, bg: :green, modifiers: [:bold]})

              selected? ->
                Span.new(" Enter: Apply ",
                  style: %Style{fg: :black, bg: :yellow, modifiers: [:bold]}
                )

              true ->
                Span.new("Apply", style: %Style{fg: :green, modifiers: [:bold]})
            end

          warn_spans =
            if Map.get(msg, :is_read_only, true) do
              []
            else
              [
                Span.new(" "),
                Span.new(" WRITE/DDL ", style: %Style{fg: :white, bg: :red, modifiers: [:bold]})
              ]
            end

          badge_line =
            Line.new([Span.new("  🤖 ", style: %Style{fg: :magenta}), badge_span] ++ warn_spans)

          expl = String.trim(to_string(Map.get(msg, :explanation) || ""))

          expl_lines =
            if expl == "" do
              []
            else
              wrap_text(expl, max(6, width - 2))
              |> Enum.map(fn ln ->
                Line.new([Span.new("  " <> ln, style: %Style{fg: :gray})])
              end)
            end

          sql = String.trim(to_string(Map.get(msg, :sql) || ""))
          sql_wrap_w = max(8, width - 4)

          sql_lines =
            if sql == "" do
              []
            else
              sql
              |> wrap_text(sql_wrap_w)
              |> Enum.map(fn ln ->
                Line.new([
                  Span.new("  │ ", style: %Style{fg: :dark_gray}),
                  Span.new(ln, style: %Style{fg: :cyan})
                ])
              end)
            end

          [badge_line] ++ expl_lines ++ sql_lines
      end

    sep =
      if divider? do
        [
          Line.new([
            Span.new("  " <> String.duplicate("─", max(6, width - 3)),
              style: %Style{fg: :dark_gray}
            )
          ])
        ]
      else
        []
      end

    [first_prompt] ++ rest_prompt ++ body_lines ++ sep
  end

  defp wrap_text("", _width), do: [""]

  defp wrap_text(text, width) when width > 0 do
    text
    |> String.split("\n")
    |> Enum.flat_map(fn line ->
      if line == "" do
        [""]
      else
        wrap_line_words(line, width)
      end
    end)
  end

  defp wrap_line_words(line, width) do
    if String.length(line) <= width do
      [line]
    else
      tokens = Regex.scan(~r/\S+\s*|\s+/, line) |> List.flatten()

      {rev_lines, current} =
        Enum.reduce(tokens, {[], ""}, fn tok, {acc, curr} ->
          cond do
            String.length(curr <> tok) <= width ->
              {acc, curr <> tok}

            String.trim_trailing(tok) != "" and
                String.length(curr <> String.trim_trailing(tok)) <= width ->
              {[curr <> String.trim_trailing(tok) | acc], ""}

            curr == "" ->
              chunks = chunk_graphemes(String.graphemes(tok), width)
              {Enum.reverse(Enum.drop(chunks, -1)) ++ acc, List.last(chunks) || ""}

            true ->
              clean_tok = String.trim_leading(tok)

              if String.length(clean_tok) <= width do
                {[String.trim_trailing(curr) | acc], clean_tok}
              else
                chunks = chunk_graphemes(String.graphemes(clean_tok), width)

                {[String.trim_trailing(curr) | Enum.reverse(Enum.drop(chunks, -1)) ++ acc],
                 List.last(chunks) || ""}
              end
          end
        end)

      final =
        if String.trim_trailing(current) == "" and rev_lines != [] do
          rev_lines
        else
          [String.trim_trailing(current) | rev_lines]
        end

      Enum.reverse(final)
    end
  end

  defp chunk_graphemes(graphemes, width) do
    graphemes
    |> Enum.chunk_every(width)
    |> Enum.map(&Enum.join/1)
  end

  defp to_rect(%{x: x, y: y, width: w, height: h}) do
    %ExRatatui.Layout.Rect{x: x, y: y, width: w, height: h}
  end
end
