defmodule Strata.UI.Components.SQLEditor do
  @moduledoc """
  Multi-tab SQL Query Editor component with cursor navigation, text editing,
  and SQL syntax highlighting.
  """

  @keywords MapSet.new(~w(
    SELECT FROM WHERE INSERT INTO UPDATE DELETE JOIN INNER LEFT RIGHT OUTER CROSS FULL
    ON GROUP BY ORDER HAVING LIMIT OFFSET AS AND OR NOT IN IS NULL LIKE ILIKE CREATE
    TABLE DROP ALTER INDEX PRIMARY KEY FOREIGN REFERENCES DEFAULT VALUES SET WITH
    UNION ALL CASE WHEN THEN ELSE END ASC DESC COUNT SUM AVG MIN MAX DISTINCT TRUE FALSE
    BOOLEAN INTEGER VARCHAR TEXT TIMESTAMP DATE
  ))

  @multiline_comment_re ~r|\A/\*.*?\*/|s
  @single_quote_re ~r/\A'(?:[^'\\]|\\.)*'/
  @double_quote_re ~r/\A"(?:[^"\\]|\\.)*"/
  @number_re ~r/^\d+(\.\d+)?/
  @ws_re ~r/^\s+/
  @ident_re ~r/^[a-zA-Z_][a-zA-Z0-9_]*/
  @op_re ~r/^(<=|>=|<>|!=|=|<|>|\+|\-|\*|\/)/
  @punct_re ~r/^(,|\(|\)|;)/

  @type cursor :: {non_neg_integer(), non_neg_integer()}
  @type token :: %{type: atom(), text: String.t()}

  @doc """
  Tokenizes a SQL string into syntax-highlighted tokens.
  """
  @spec tokenize(String.t()) :: [token()]
  def tokenize(sql) when is_binary(sql) do
    do_tokenize(sql, [])
  end

  defp do_tokenize("", acc), do: Enum.reverse(acc)

  defp do_tokenize(sql, acc) do
    cond do
      # Comments (-- ...)
      String.starts_with?(sql, "--") ->
        {comment, rest} = split_at_newline(sql)
        do_tokenize(rest, [%{type: :comment, text: comment} | acc])

      # Multi-line comments (/* ... */)
      String.starts_with?(sql, "/*") ->
        case Regex.run(@multiline_comment_re, sql) do
          [matched] ->
            rest = String.slice(sql, String.length(matched)..-1//1)
            do_tokenize(rest, [%{type: :comment, text: matched} | acc])

          nil ->
            # Unclosed comment
            do_tokenize("", [%{type: :comment, text: sql} | acc])
        end

      # Strings ('...' or "...")
      String.starts_with?(sql, "'") ->
        case Regex.run(@single_quote_re, sql) do
          [matched] ->
            rest = String.slice(sql, String.length(matched)..-1//1)
            do_tokenize(rest, [%{type: :string, text: matched} | acc])

          nil ->
            {str, rest} = split_at_newline(sql)
            do_tokenize(rest, [%{type: :string, text: str} | acc])
        end

      String.starts_with?(sql, "\"") ->
        case Regex.run(@double_quote_re, sql) do
          [matched] ->
            rest = String.slice(sql, String.length(matched)..-1//1)
            do_tokenize(rest, [%{type: :string, text: matched} | acc])

          nil ->
            {str, rest} = split_at_newline(sql)
            do_tokenize(rest, [%{type: :string, text: str} | acc])
        end

      # Numbers (\d+(\.\d+)?)
      matched = Regex.run(@number_re, sql) ->
        [num | _] = matched
        rest = String.slice(sql, String.length(num)..-1//1)
        do_tokenize(rest, [%{type: :number, text: num} | acc])

      # Whitespace
      matched = Regex.run(@ws_re, sql) ->
        [ws | _] = matched
        rest = String.slice(sql, String.length(ws)..-1//1)
        do_tokenize(rest, [%{type: :whitespace, text: ws} | acc])

      # Identifiers / Words
      matched = Regex.run(@ident_re, sql) ->
        [word | _] = matched
        rest = String.slice(sql, String.length(word)..-1//1)
        type = if MapSet.member?(@keywords, String.upcase(word)), do: :keyword, else: :identifier
        do_tokenize(rest, [%{type: type, text: word} | acc])

      # Operators
      matched = Regex.run(@op_re, sql) ->
        [op | _] = matched
        rest = String.slice(sql, String.length(op)..-1//1)
        do_tokenize(rest, [%{type: :operator, text: op} | acc])

      # Punctuation
      matched = Regex.run(@punct_re, sql) ->
        [punct | _] = matched
        rest = String.slice(sql, String.length(punct)..-1//1)
        do_tokenize(rest, [%{type: :punctuation, text: punct} | acc])

      # Any single fallback character
      true ->
        char = String.first(sql)
        rest = String.slice(sql, 1..-1//1)
        do_tokenize(rest, [%{type: :unknown, text: char} | acc])
    end
  end

  defp split_at_newline(sql) do
    case String.split(sql, "\n", parts: 2) do
      [line, rest] -> {line, rest}
      [line] -> {line, ""}
    end
  end

  @doc """
  Inserts `text` into multi-line `content` at `{row, col}` cursor.
  Returns `{updated_content, new_cursor}`.
  """
  @spec insert_text(String.t(), cursor(), String.t()) :: {String.t(), cursor()}
  def insert_text(content, {row, col}, text) do
    lines = String.split(content, "\n")
    row = max(0, min(length(lines) - 1, row))
    target_line = Enum.at(lines, row, "")

    col = max(0, min(String.length(target_line), col))
    prefix = String.slice(target_line, 0, col)
    suffix = String.slice(target_line, col..-1//1)

    inserted_lines = String.split(text, "\n")

    new_lines =
      case inserted_lines do
        [single] ->
          List.replace_at(lines, row, prefix <> single <> suffix)

        [first | rest] ->
          {middle, [last]} = Enum.split(rest, max(0, length(rest) - 1))
          first_combined = prefix <> first
          last_combined = last <> suffix

          {before_lines, after_lines} = Enum.split(lines, row)
          # after_lines contains target_line as first item, drop it
          tail_after = Enum.drop(after_lines, 1)

          before_lines ++ [first_combined] ++ middle ++ [last_combined] ++ tail_after
      end

    new_row = row + length(inserted_lines) - 1

    new_col =
      if length(inserted_lines) == 1 do
        col + String.length(text)
      else
        String.length(List.last(inserted_lines))
      end

    {Enum.join(new_lines, "\n"), {new_row, new_col}}
  end

  @doc """
  Deletes the character before `{row, col}` cursor (backspace).
  Returns `{updated_content, new_cursor}`.
  """
  @spec backspace(String.t(), cursor()) :: {String.t(), cursor()}
  def backspace(content, {row, col}) do
    lines = String.split(content, "\n")
    row = max(0, min(length(lines) - 1, row))
    line = Enum.at(lines, row, "")
    col = max(0, min(String.length(line), col))

    cond do
      col > 0 ->
        prefix = String.slice(line, 0, col - 1)
        suffix = String.slice(line, col..-1//1)
        updated_lines = List.replace_at(lines, row, prefix <> suffix)
        {Enum.join(updated_lines, "\n"), {row, col - 1}}

      col == 0 and row > 0 ->
        prev_line = Enum.at(lines, row - 1, "")
        joined = prev_line <> line

        {before_prev, from_prev} = Enum.split(lines, row - 1)
        # from_prev has [prev_line, line | tail]
        tail = Enum.drop(from_prev, 2)

        updated_lines = before_prev ++ [joined] ++ tail
        {Enum.join(updated_lines, "\n"), {row - 1, String.length(prev_line)}}

      true ->
        {content, {row, col}}
    end
  end

  @doc """
  Deletes character at `{row, col}` cursor (delete key).
  Returns `{updated_content, cursor}`.
  """
  @spec delete_char(String.t(), cursor()) :: {String.t(), cursor()}
  def delete_char(content, {row, col}) do
    lines = String.split(content, "\n")
    row = max(0, min(length(lines) - 1, row))
    line = Enum.at(lines, row, "")
    col = max(0, min(String.length(line), col))
    line_len = String.length(line)

    cond do
      col < line_len ->
        prefix = String.slice(line, 0, col)
        suffix = String.slice(line, (col + 1)..-1//1)
        updated_lines = List.replace_at(lines, row, prefix <> suffix)
        {Enum.join(updated_lines, "\n"), {row, col}}

      col == line_len and row < length(lines) - 1 ->
        next_line = Enum.at(lines, row + 1, "")
        joined = line <> next_line

        {before_curr, from_curr} = Enum.split(lines, row)
        tail = Enum.drop(from_curr, 2)

        updated_lines = before_curr ++ [joined] ++ tail
        {Enum.join(updated_lines, "\n"), {row, col}}

      true ->
        {content, {row, col}}
    end
  end

  @doc """
  Moves cursor within `content` according to `direction`.
  """
  @spec move_cursor(String.t(), cursor(), atom()) :: cursor()
  def move_cursor(content, {row, col}, direction) do
    lines = String.split(content, "\n")
    total_rows = length(lines)
    row = max(0, min(total_rows - 1, row))
    line_len = String.length(Enum.at(lines, row, ""))

    case direction do
      :left ->
        if col > 0 do
          {row, col - 1}
        else
          if row > 0 do
            {row - 1, String.length(Enum.at(lines, row - 1, ""))}
          else
            {0, 0}
          end
        end

      :right ->
        if col < line_len do
          {row, col + 1}
        else
          if row < total_rows - 1 do
            {row + 1, 0}
          else
            {row, line_len}
          end
        end

      :up ->
        if row > 0 do
          target_row = row - 1
          target_len = String.length(Enum.at(lines, target_row, ""))
          {target_row, min(col, target_len)}
        else
          {0, min(col, line_len)}
        end

      :down ->
        if row < total_rows - 1 do
          target_row = row + 1
          target_len = String.length(Enum.at(lines, target_row, ""))
          {target_row, min(col, target_len)}
        else
          {row, min(col, line_len)}
        end

      :home ->
        {row, 0}

      :end ->
        {row, line_len}

      :page_up ->
        target_row = max(0, row - 10)
        target_len = String.length(Enum.at(lines, target_row, ""))
        {target_row, min(col, target_len)}

      :page_down ->
        target_row = min(total_rows - 1, row + 10)
        target_len = String.length(Enum.at(lines, target_row, ""))
        {target_row, min(col, target_len)}

      _other ->
        {row, min(col, line_len)}
    end
  end

  @doc """
  Moves cursor within `content` along visual rows of width `code_width` for
  vertical navigation (`:up`, `:down`, `:page_up`, `:page_down`), falling back
  to `move_cursor/3` for horizontal navigation.
  """
  @spec move_cursor_visual(String.t(), cursor(), atom(), pos_integer()) :: cursor()
  def move_cursor_visual(content, cursor, direction, code_width)
      when direction in [:up, :down, :page_up, :page_down] and is_integer(code_width) and
             code_width > 0 do
    layout = visual_layout(content, cursor, code_width)
    v_lines = layout.visual_lines
    {v_row, v_col} = layout.cursor_v_pos
    step = if direction in [:page_up, :page_down], do: 10, else: 1

    target_v_row =
      case direction do
        d when d in [:up, :page_up] -> max(0, v_row - step)
        d when d in [:down, :page_down] -> min(length(v_lines) - 1, v_row + step)
      end

    target_vl = Enum.at(v_lines, target_v_row)
    next_vl = Enum.at(v_lines, target_v_row + 1)

    has_next_continuation? =
      next_vl != nil and next_vl.logical_row == target_vl.logical_row and next_vl.continued?

    max_col =
      if has_next_continuation? and target_vl.end_col > target_vl.start_col do
        target_vl.end_col - 1
      else
        target_vl.end_col
      end

    {target_vl.logical_row, min(max_col, target_vl.start_col + v_col)}
  end

  def move_cursor_visual(content, cursor, direction, _code_width) do
    move_cursor(content, cursor, direction)
  end

  @doc """
  Computes line-number gutter digits for `line_count` logical lines.
  """
  @spec gutter_digits(non_neg_integer()) :: pos_integer()
  def gutter_digits(line_count) do
    max(3, String.length(Integer.to_string(max(1, line_count))))
  end

  @doc """
  Computes editor gutter, code width, and viewport height from `content` and `editor_area`.
  Shared between `Renderer`, `App`, `Selection`, and `SQLEditor`.
  """
  @spec editor_metrics(String.t(), map()) :: %{
          digits: pos_integer(),
          gutter_width: pos_integer(),
          code_width: pos_integer(),
          body_height: pos_integer(),
          viewport_h: pos_integer()
        }
  def editor_metrics(content, editor_area) do
    line_count = content |> to_string() |> String.split("\n") |> length()
    digits = gutter_digits(line_count)
    gutter_width = digits + 3
    body_height = max(1, Map.get(editor_area, :height, 10))
    viewport_h = max(1, body_height - 2)
    code_width = max(1, Map.get(editor_area, :width, 80) - 2 - gutter_width)

    %{
      digits: digits,
      gutter_width: gutter_width,
      code_width: code_width,
      body_height: body_height,
      viewport_h: viewport_h
    }
  end

  @doc """
  Wraps logical lines of `content` to `code_width` without mutating `content` with
  `\\n`, returning visual line records and `{visual_row, visual_col}` cursor coordinates.
  """
  @spec visual_layout(String.t(), cursor(), pos_integer() | nil) :: %{
          visual_lines: [map()],
          cursor_v_pos: {non_neg_integer(), non_neg_integer()},
          gutter_width: pos_integer(),
          digits: pos_integer()
        }
  def visual_layout(content, cursor \\ {0, 0}, code_width \\ nil) do
    logical_lines = String.split(content || "", "\n")
    total_logical = length(logical_lines)
    digits = gutter_digits(total_logical)
    gutter_width = digits + 3
    cont_prefix = String.duplicate(" ", digits) <> " │ "

    {raw_r, raw_c} = cursor || {0, 0}
    cur_row = max(0, min(total_logical - 1, raw_r))
    cur_line_len = logical_lines |> Enum.at(cur_row, "") |> String.length()
    cur_col = max(0, min(cur_line_len, raw_c))

    wrap_w =
      if is_integer(code_width) and code_width > 0, do: code_width, else: nil

    {rev_vlines, cursor_v_pos, _v_idx} =
      logical_lines
      |> Enum.with_index()
      |> Enum.reduce({[], {0, 0}, 0}, fn {line, idx}, {acc, c_vpos, v_idx} ->
        line_num = String.pad_leading("#{idx + 1}", digits, " ")
        first_prefix = "#{line_num} │ "
        tokens = Strata.UI.Cache.fetch(:sql_tokens, line, 500, fn -> tokenize(line) end)
        line_len = String.length(line)

        ranges =
          visual_ranges_for_line(
            line_len,
            wrap_w,
            idx == cur_row,
            cur_col
          )

        last_seg_idx = length(ranges) - 1

        ranges
        |> Enum.with_index()
        |> Enum.reduce({acc, c_vpos, v_idx}, fn {{s_col, e_col}, seg_idx},
                                                {seg_acc, seg_cpos, cur_v_idx} ->
          continued? = seg_idx > 0
          prefix = if continued?, do: cont_prefix, else: first_prefix
          seg_text = String.slice(line, s_col, e_col - s_col)
          seg_tokens = slice_tokens(tokens, s_col, e_col)

          has_cursor? =
            idx == cur_row and
              ((cur_col >= s_col and cur_col < e_col) or
                 (seg_idx == last_seg_idx and cur_col == e_col))

          local_col = if has_cursor?, do: cur_col - s_col, else: nil
          next_cpos = if has_cursor?, do: {cur_v_idx, local_col}, else: seg_cpos

          vl = %{
            v_row: cur_v_idx,
            logical_row: idx,
            line_number: idx + 1,
            start_col: s_col,
            end_col: e_col,
            continued?: continued?,
            prefix: prefix,
            text: seg_text,
            tokens: seg_tokens,
            has_cursor?: has_cursor?,
            cursor_col: local_col
          }

          {[vl | seg_acc], next_cpos, cur_v_idx + 1}
        end)
      end)

    %{
      visual_lines: Enum.reverse(rev_vlines),
      cursor_v_pos: cursor_v_pos,
      gutter_width: gutter_width,
      digits: digits
    }
  end

  defp visual_ranges_for_line(0, _wrap_w, _is_cur_row?, _cur_col), do: [{0, 0}]

  defp visual_ranges_for_line(line_len, nil, _is_cur_row?, _cur_col), do: [{0, line_len}]

  defp visual_ranges_for_line(line_len, wrap_w, is_cur_row?, cur_col) do
    chunk_count = div(line_len + wrap_w - 1, wrap_w)

    base =
      Enum.map(0..(chunk_count - 1), fn i ->
        s = i * wrap_w
        {s, min(line_len, s + wrap_w)}
      end)

    if is_cur_row? and cur_col == line_len and rem(line_len, wrap_w) == 0 do
      base ++ [{line_len, line_len}]
    else
      base
    end
  end

  defp slice_tokens(tokens, start_col, end_col) do
    if end_col <= start_col do
      []
    else
      {rev_sliced, _pos} =
        Enum.reduce(tokens, {[], 0}, fn tok, {acc, pos} ->
          tok_len = String.length(tok.text)
          tok_end = pos + tok_len
          ov_start = max(pos, start_col)
          ov_end = min(tok_end, end_col)

          next_acc =
            if ov_end > ov_start do
              sliced_text = String.slice(tok.text, ov_start - pos, ov_end - ov_start)
              [%{tok | text: sliced_text} | acc]
            else
              acc
            end

          {next_acc, tok_end}
        end)

      Enum.reverse(rev_sliced)
    end
  end

  alias Strata.UI.Components.SQLCompleter
  alias Strata.UI.Components.SQLLinter

  @doc """
  Computes effective `scroll_top` for an active `:query` tab inside `editor_area`,
  preserving manual mouse scroll (`tab.scroll_offset`) while falling back to cursor
  auto-follow when `scroll_offset` is unset.
  """
  @spec effective_scroll_top(map() | nil, map()) :: non_neg_integer()
  def effective_scroll_top(nil, _editor_area), do: 0

  def effective_scroll_top(active_tab, editor_area) do
    content = Map.get(active_tab, :content, "") || ""
    cursor = Map.get(active_tab, :cursor, {0, 0}) || {0, 0}
    %{code_width: cw, viewport_h: vh} = editor_metrics(content, editor_area)
    v_layout = visual_layout(content, cursor, cw)
    total_v = length(v_layout.visual_lines)
    max_top = max(0, total_v - vh)
    {v_row, _} = v_layout.cursor_v_pos

    case Map.get(active_tab, :scroll_offset) do
      offset when is_integer(offset) and offset >= 0 ->
        min(offset, max_top)

      _ ->
        min(max(0, v_row - vh + 1), max_top)
    end
  end

  @doc """
  Returns the maximum vertical scroll offset for `active_tab` inside `editor_area`.
  """
  @spec max_scroll_offset(map() | nil, map()) :: non_neg_integer()
  def max_scroll_offset(nil, _editor_area), do: 0

  def max_scroll_offset(active_tab, editor_area) do
    content = Map.get(active_tab, :content, "") || ""
    cursor = Map.get(active_tab, :cursor, {0, 0}) || {0, 0}
    %{code_width: cw, viewport_h: vh} = editor_metrics(content, editor_area)
    total_v = length(visual_layout(content, cursor, cw).visual_lines)
    max(0, total_v - vh)
  end

  @doc """
  Adjusts `tab.scroll_offset` on the active SQL tab by `delta` visual lines, clamped cleanly.
  """
  @spec scroll_viewport(map(), map(), integer()) :: map()
  def scroll_viewport(app, editor_area, delta) when is_integer(delta) do
    active_tab = Enum.find(Map.get(app, :tabs, []), &(&1.id == Map.get(app, :active_tab_id)))

    if active_tab do
      current = effective_scroll_top(active_tab, editor_area)
      max_top = max_scroll_offset(active_tab, editor_area)
      next_offset = max(0, min(max_top, current + delta))
      update_active_tab(app, Map.put(active_tab, :scroll_offset, next_offset))
    else
      app
    end
  end

  defp ensure_cursor_visible(app, tab, editor_area) do
    case Map.get(tab, :scroll_offset) do
      curr
      when is_integer(curr) and is_map(editor_area) and editor_area.height > 0 and
             editor_area.width > 0 ->
        content = Map.get(tab, :content, "") || ""
        cursor = Map.get(tab, :cursor, {0, 0}) || {0, 0}
        %{code_width: cw, viewport_h: vh} = editor_metrics(content, editor_area)
        v_layout = visual_layout(content, cursor, cw)
        total_v = length(v_layout.visual_lines)
        max_top = max(0, total_v - vh)
        {v_row, _} = v_layout.cursor_v_pos

        next_offset =
          cond do
            v_row < curr -> v_row
            v_row >= curr + vh -> v_row - vh + 1
            true -> curr
          end
          |> max(0)
          |> min(max_top)

        update_active_tab(app, Map.put(tab, :scroll_offset, next_offset))

      _ ->
        update_active_tab(app, tab)
    end
  end

  @doc """
  Handles keypress events for active SQL editor tab.
  """
  def handle_key(app, key) do
    active_tab = Enum.find(app.tabs, &(&1.id == app.active_tab_id))

    if active_tab do
      comp =
        Map.get(active_tab, :completion, %{
          active?: false,
          suggestions: [],
          selected_index: 0,
          prefix: ""
        })

      editor_area =
        if is_tuple(Map.get(app, :window_size)) do
          Strata.UI.Renderer.layout(
            app.window_size,
            Map.get(app, :active_view, :query_view)
          ).editor
        else
          nil
        end

      cond do
        key == {:ctrl, "space"} ->
          {prefix, _start_c} = SQLCompleter.extract_prefix(active_tab.content, active_tab.cursor)
          table_cols = Strata.DataStore.cached_columns(Map.get(active_tab, :profile_id))

          suggs =
            SQLCompleter.suggestions(prefix,
              sidebar_nodes: app.sidebar_nodes,
              table_columns: table_cols,
              sql: active_tab.content,
              cursor: active_tab.cursor,
              allow_empty_prefix: true
            )

          new_comp =
            if suggs != [] do
              %{active?: true, suggestions: suggs, selected_index: 0, prefix: prefix}
            else
              %{active?: false, suggestions: [], selected_index: 0, prefix: ""}
            end

          update_active_tab_completion(app, active_tab, new_comp)

        comp.active? and key == :down ->
          cnt = max(1, length(comp.suggestions))
          new_idx = rem(comp.selected_index + 1, cnt)
          update_active_tab_completion(app, active_tab, %{comp | selected_index: new_idx})

        comp.active? and key == :up ->
          cnt = max(1, length(comp.suggestions))
          new_idx = rem(comp.selected_index - 1 + cnt, cnt)
          update_active_tab_completion(app, active_tab, %{comp | selected_index: new_idx})

        comp.active? and key in [:enter, :tab] ->
          sug = Enum.at(comp.suggestions, comp.selected_index)

          if sug do
            {new_content, new_cursor} =
              SQLCompleter.apply_completion(
                active_tab.content,
                active_tab.cursor,
                sug,
                comp.prefix
              )

            table_cols = Strata.DataStore.cached_columns(Map.get(active_tab, :profile_id))

            diags =
              SQLLinter.check(new_content,
                sidebar_nodes: app.sidebar_nodes,
                table_columns: table_cols
              )

            new_comp = %{active?: false, suggestions: [], selected_index: 0, prefix: ""}

            updated_tab =
              %{active_tab | content: new_content, cursor: new_cursor}
              |> Map.put(:completion, new_comp)
              |> Map.put(:diagnostics, diags)

            ensure_cursor_visible(app, updated_tab, editor_area)
          else
            update_active_tab_completion(app, active_tab, %{comp | active?: false})
          end

        comp.active? and key == :esc ->
          update_active_tab_completion(app, active_tab, %{comp | active?: false})

        true ->
          {new_content, new_cursor} =
            case key do
              char when is_binary(char) ->
                insert_text(active_tab.content, active_tab.cursor, char)

              {:char, char} ->
                insert_text(active_tab.content, active_tab.cursor, char)

              {:paste, text} ->
                insert_text(active_tab.content, active_tab.cursor, text)

              {:ctrl, "k"} ->
                {"", {0, 0}}

              :tab ->
                insert_text(active_tab.content, active_tab.cursor, "  ")

              :enter ->
                insert_text(active_tab.content, active_tab.cursor, "\n")

              :backspace ->
                backspace(active_tab.content, active_tab.cursor)

              :delete ->
                delete_char(active_tab.content, active_tab.cursor)

              nav when nav in [:left, :right, :up, :down, :home, :end, :page_up, :page_down] ->
                new_cursor =
                  if nav in [:up, :down, :page_up, :page_down] and
                       is_map(editor_area) and editor_area.height > 0 and editor_area.width > 0 do
                    %{code_width: cw} = editor_metrics(active_tab.content, editor_area)
                    move_cursor_visual(active_tab.content, active_tab.cursor, nav, cw)
                  else
                    move_cursor(active_tab.content, active_tab.cursor, nav)
                  end

                {active_tab.content, new_cursor}

              _other ->
                {active_tab.content, active_tab.cursor}
            end

          editing_key? =
            is_binary(key) or match?({:char, _}, key) or match?({:paste, _}, key) or
              key in [:backspace, :delete]

          table_cols =
            Strata.DataStore.cached_columns(Map.get(active_tab, :profile_id))

          new_comp =
            if editing_key? do
              {prefix, _start_c} = SQLCompleter.extract_prefix(new_content, new_cursor)
              {_stmt, before_cur} = SQLCompleter.statement_at_cursor(new_content, new_cursor)
              clause = SQLCompleter.suggest_type(before_cur, prefix)

              trigger_char =
                case key do
                  c when is_binary(c) -> c
                  {:char, c} -> c
                  _ -> nil
                end

              allow_empty? =
                trigger_char == "." or
                  (trigger_char == " " and clause in [:table, :column] and
                     clause_keyword_before_space?(before_cur))

              suggs =
                SQLCompleter.suggestions(prefix,
                  sidebar_nodes: app.sidebar_nodes,
                  table_columns: table_cols,
                  sql: new_content,
                  cursor: new_cursor,
                  allow_empty_prefix: allow_empty?
                )

              exact_only? =
                case suggs do
                  [only] when prefix != "" ->
                    String.downcase(only.insert_text) == String.downcase(prefix)

                  _ ->
                    false
                end

              if suggs != [] and (String.length(prefix) >= 1 or allow_empty?) and not exact_only? do
                %{active?: true, suggestions: suggs, selected_index: 0, prefix: prefix}
              else
                %{active?: false, suggestions: [], selected_index: 0, prefix: ""}
              end
            else
              %{active?: false, suggestions: [], selected_index: 0, prefix: ""}
            end

          diags =
            if editing_key? do
              SQLLinter.check(new_content,
                sidebar_nodes: app.sidebar_nodes,
                table_columns: table_cols
              )
            else
              Map.get(active_tab, :diagnostics, [])
            end

          updated_tab =
            %{active_tab | content: new_content, cursor: new_cursor}
            |> Map.put(:completion, new_comp)
            |> Map.put(:diagnostics, diags)

          ensure_cursor_visible(app, updated_tab, editor_area)
      end
    else
      app
    end
  end

  defp clause_keyword_before_space?(before_cur) do
    trimmed = String.trim_trailing(before_cur)

    Regex.match?(
      ~r/\b(?:FROM|JOIN|UPDATE|INTO|WHERE|ON|AND|OR|SET|HAVING|GROUP\s+BY|ORDER\s+BY)\s*$/i,
      trimmed
    )
  end

  defp update_active_tab(app, updated_tab) do
    updated_tabs =
      Enum.map(app.tabs, fn t ->
        if t.id == updated_tab.id, do: updated_tab, else: t
      end)

    %{app | tabs: updated_tabs}
  end

  defp update_active_tab_completion(app, active_tab, new_comp) do
    updated_tab = Map.put(active_tab, :completion, new_comp)
    update_active_tab(app, updated_tab)
  end

  @doc """
  Returns list of formatted tab titles for ExRatatui.Widgets.Tabs.
  """
  @spec tab_titles(map()) :: [String.t()]
  def tab_titles(app) do
    Enum.map(Enum.with_index(app.tabs), fn {t, idx} ->
      star = if t.id == app.active_tab_id, do: "★ ", else: ""
      "#{star}#{idx + 1}: #{t.name}"
    end)
  end

  @doc """
  Returns 0-based index of active tab.
  """
  @spec active_tab_index(map()) :: non_neg_integer()
  def active_tab_index(app) do
    Enum.find_index(app.tabs, &(&1.id == app.active_tab_id)) || 0
  end

  @doc """
  Renders editor pane state for given area.
  """
  def render(app, area) do
    active_tab = Enum.find(app.tabs, &(&1.id == app.active_tab_id))
    content = if active_tab, do: active_tab.content, else: ""
    cursor = if active_tab, do: active_tab.cursor, else: {0, 0}
    active_idx = active_tab_index(app)
    titles = tab_titles(app)

    comp =
      Map.get(active_tab || %{}, :completion, %{
        active?: false,
        suggestions: [],
        selected_index: 0,
        prefix: ""
      })

    %{code_width: code_width} = editor_metrics(content, area)
    v_layout = visual_layout(content, cursor, code_width)

    %{
      title: "SQL EDITOR",
      area: area,
      active_tab: active_tab,
      active_index: active_idx,
      tab_titles: titles,
      lines: v_layout.visual_lines,
      cursor: cursor,
      cursor_v_pos: v_layout.cursor_v_pos,
      gutter_width: v_layout.gutter_width,
      code_width: code_width,
      completion: comp,
      diagnostics: Map.get(active_tab || %{}, :diagnostics, [])
    }
  end
end
