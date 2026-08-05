defmodule DBData.UI.Components.SQLEditor do
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
        case Regex.run(~r|\A/\*.*?\*/|s, sql) do
          [matched] ->
            rest = String.slice(sql, String.length(matched)..-1//1)
            do_tokenize(rest, [%{type: :comment, text: matched} | acc])

          nil ->
            # Unclosed comment
            do_tokenize("", [%{type: :comment, text: sql} | acc])
        end

      # Strings ('...' or "...")
      String.starts_with?(sql, "'") or String.starts_with?(sql, "\"") ->
        quote_char = String.first(sql)
        pattern = Regex.compile!("\\A#{quote_char}(?:[^#{quote_char}\\\\]|\\\\.)*#{quote_char}")

        case Regex.run(pattern, sql) do
          [matched] ->
            rest = String.slice(sql, String.length(matched)..-1//1)
            do_tokenize(rest, [%{type: :string, text: matched} | acc])

          nil ->
            {str, rest} = split_at_newline(sql)
            do_tokenize(rest, [%{type: :string, text: str} | acc])
        end

      # Numbers (\d+(\.\d+)?)
      matched = Regex.run(~r/^\d+(\.\d+)?/, sql) ->
        [num | _] = matched
        rest = String.slice(sql, String.length(num)..-1//1)
        do_tokenize(rest, [%{type: :number, text: num} | acc])

      # Whitespace
      matched = Regex.run(~r/^\s+/, sql) ->
        [ws | _] = matched
        rest = String.slice(sql, String.length(ws)..-1//1)
        do_tokenize(rest, [%{type: :whitespace, text: ws} | acc])

      # Identifiers / Words
      matched = Regex.run(~r/^[a-zA-Z_][a-zA-Z0-9_]*/, sql) ->
        [word | _] = matched
        rest = String.slice(sql, String.length(word)..-1//1)
        type = if MapSet.member?(@keywords, String.upcase(word)), do: :keyword, else: :identifier
        do_tokenize(rest, [%{type: type, text: word} | acc])

      # Operators
      matched = Regex.run(~r/^(<=|>=|<>|!=|=|<|>|\+|\-|\*|\/)/, sql) ->
        [op | _] = matched
        rest = String.slice(sql, String.length(op)..-1//1)
        do_tokenize(rest, [%{type: :operator, text: op} | acc])

      # Punctuation
      matched = Regex.run(~r/^(,|\(|\)|;)/, sql) ->
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
  Handles keypress events for active SQL editor tab.
  """
  def handle_key(app, key) do
    active_tab = Enum.find(app.tabs, &(&1.id == app.active_tab_id))

    if active_tab do
      {new_content, new_cursor} =
        case key do
          {:char, char} ->
            insert_text(active_tab.content, active_tab.cursor, char)

          :enter ->
            insert_text(active_tab.content, active_tab.cursor, "\n")

          :backspace ->
            backspace(active_tab.content, active_tab.cursor)

          :delete ->
            delete_char(active_tab.content, active_tab.cursor)

          nav when nav in [:left, :right, :up, :down, :home, :end, :page_up, :page_down] ->
            {active_tab.content, move_cursor(active_tab.content, active_tab.cursor, nav)}

          _other ->
            {active_tab.content, active_tab.cursor}
        end

      updated_tabs =
        Enum.map(app.tabs, fn t ->
          if t.id == active_tab.id do
            %{t | content: new_content, cursor: new_cursor}
          else
            t
          end
        end)

      %{app | tabs: updated_tabs}
    else
      app
    end
  end

  @doc """
  Renders editor pane state for given area.
  """
  def render(app, area) do
    active_tab = Enum.find(app.tabs, &(&1.id == app.active_tab_id))
    content = if active_tab, do: active_tab.content, else: ""
    cursor = if active_tab, do: active_tab.cursor, else: {0, 0}

    lines =
      content
      |> String.split("\n")
      |> Enum.with_index()
      |> Enum.map(fn {line, idx} ->
        line_num = String.pad_leading("#{idx + 1}", 3, " ")
        tokens = tokenize(line)

        %{
          line_number: idx + 1,
          prefix: "#{line_num} │ ",
          text: line,
          tokens: tokens,
          has_cursor?: elem(cursor, 0) == idx,
          cursor_col: if(elem(cursor, 0) == idx, do: elem(cursor, 1), else: nil)
        }
      end)

    %{
      title: "SQL EDITOR",
      area: area,
      active_tab: active_tab,
      lines: lines,
      cursor: cursor
    }
  end
end
