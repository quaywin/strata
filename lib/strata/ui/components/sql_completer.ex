defmodule Strata.UI.Components.SQLCompleter do
  @moduledoc """
  Context-aware autocomplete engine for SQL keywords, schema table names,
  table aliases, and column names (`pgcli`-style `suggest_type` + `extract_table_refs`).
  """

  @keywords ~w(
    SELECT FROM WHERE INSERT INTO UPDATE DELETE JOIN INNER LEFT RIGHT OUTER CROSS FULL
    ON GROUP BY ORDER HAVING LIMIT OFFSET AS AND OR NOT IN IS NULL LIKE ILIKE CREATE
    TABLE DROP ALTER INDEX PRIMARY KEY FOREIGN REFERENCES DEFAULT VALUES SET WITH
    UNION ALL CASE WHEN THEN ELSE END ASC DESC COUNT SUM AVG MIN MAX DISTINCT TRUE FALSE
    BOOLEAN INTEGER VARCHAR TEXT TIMESTAMP DATE COALESCE EXISTS BETWEEN
  )

  @non_alias_keywords MapSet.new(~w(
    WHERE ON SET VALUES SELECT FROM JOIN INNER LEFT RIGHT OUTER CROSS FULL
    NATURAL USING GROUP ORDER HAVING LIMIT OFFSET UNION EXCEPT INTERSECT
    AND OR RETURNING INTO AS WHEN THEN ELSE END CASE WITH
  ))

  @table_clause_keywords ~w(FROM JOIN UPDATE INTO TABLE)
  @column_clause_keywords ~w(SELECT WHERE ON AND OR NOT SET HAVING BY WHEN CASE)

  @type suggestion :: %{
          label: String.t(),
          type: :keyword | :table | :column,
          insert_text: String.t(),
          detail: String.t() | nil
        }

  @doc """
  Extracts current prefix word immediately preceding cursor `{row, col}`.
  Returns `{prefix_word, start_col}`.
  """
  @spec extract_prefix(String.t(), {non_neg_integer(), non_neg_integer()}) ::
          {String.t(), non_neg_integer()}
  def extract_prefix(content, {row, col}) when is_binary(content) do
    lines = String.split(content, "\n")
    line = Enum.at(lines, max(0, min(length(lines) - 1, row)), "")
    col = max(0, min(String.length(line), col))

    prefix_line = String.slice(line, 0, col)

    case Regex.run(~r/([a-zA-Z0-9_\.]+)$/, prefix_line) do
      [matched | _] ->
        start_c = col - String.length(matched)
        {matched, start_c}

      nil ->
        {"", col}
    end
  end

  @doc """
  Extracts the SQL statement around `cursor` (split by `;` outside quotes/comments)
  along with `{statement_text, text_before_cursor_in_statement}`.
  """
  @spec statement_at_cursor(String.t(), {non_neg_integer(), non_neg_integer()}) ::
          {String.t(), String.t()}
  def statement_at_cursor(content, {row, col}) when is_binary(content) do
    lines = String.split(content, "\n")
    clamped_row = max(0, min(length(lines) - 1, row))

    cursor_offset =
      lines
      |> Enum.take(clamped_row)
      |> Enum.reduce(0, fn line, acc -> acc + String.length(line) + 1 end)
      |> Kernel.+(max(0, min(String.length(Enum.at(lines, clamped_row, "")), col)))

    boundaries = semicolon_positions(content)

    start_pos =
      boundaries
      |> Enum.filter(&(&1 < cursor_offset))
      |> List.last()
      |> case do
        nil -> 0
        idx -> idx + 1
      end

    end_pos =
      boundaries
      |> Enum.find(&(&1 >= cursor_offset))
      |> case do
        nil -> String.length(content)
        idx -> idx
      end

    stmt = String.slice(content, start_pos, max(0, end_pos - start_pos))
    before = String.slice(content, start_pos, max(0, cursor_offset - start_pos))
    {stmt, before}
  end

  def statement_at_cursor(_, _), do: {"", ""}

  defp semicolon_positions(text) do
    text
    |> String.graphemes()
    |> Enum.with_index()
    |> Enum.reduce({[], false, false}, fn {ch, idx}, {acc, in_quote?, in_line_comment?} ->
      cond do
        in_line_comment? and ch == "\n" ->
          {acc, in_quote?, false}

        in_line_comment? ->
          {acc, in_quote?, true}

        not in_quote? and ch == "-" and String.at(text, idx + 1) == "-" ->
          {acc, false, true}

        ch == "'" ->
          {acc, not in_quote?, false}

        not in_quote? and ch == ";" ->
          {[idx | acc], false, false}

        true ->
          {acc, in_quote?, false}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  @doc """
  Extracts table names from all sidebar tree nodes (including collapsed branches).
  """
  @spec extract_tables([map()]) :: [String.t()]
  def extract_tables(nodes) when is_list(nodes) do
    nodes
    |> collect_tables([])
    |> Enum.reverse()
    |> Enum.uniq()
  end

  defp collect_tables([], acc), do: acc

  defp collect_tables([node | rest], acc) do
    acc =
      if Map.get(node, :type) in [:table, :view] do
        [Map.get(node, :label, "") | acc]
      else
        acc
      end

    children = Map.get(node, :children, [])
    acc = collect_tables(children, acc)
    collect_tables(rest, acc)
  end

  @clause_stop_lookahead ~S"(?:WHERE|ON|SET|VALUES|SELECT|FROM|JOIN|INNER|LEFT|RIGHT|OUTER|CROSS|FULL|NATURAL|USING|GROUP|ORDER|HAVING|LIMIT|OFFSET|UNION|EXCEPT|INTERSECT|AND|OR|RETURNING|INTO|AS|WHEN|THEN|ELSE|END|CASE|WITH)\b"

  @doc """
  Extracts `{tables, aliases}` referenced in `sql` (e.g. `FROM users u`, `JOIN orders AS o`,
  comma joins, `UPDATE`, `INTO`, plus CTE names from `WITH`).
  """
  @spec extract_table_refs(String.t()) :: {[String.t()], %{String.t() => String.t()}}
  def extract_table_refs(sql) when is_binary(sql) do
    regex =
      ~r/\b(?:FROM|JOIN|UPDATE|INTO)\s+(?:[a-zA-Z0-9_"]+\.)?("?[a-zA-Z0-9_]+"?)(?:\s+(?:AS\s+)?(?!#{@clause_stop_lookahead})([a-zA-Z_][a-zA-Z0-9_]*))?/i

    {tbls, aliases} =
      Regex.scan(regex, sql)
      |> Enum.reduce({[], %{}}, fn match, {t_acc, a_acc} ->
        tbl = match |> Enum.at(1, "") |> String.replace("\"", "")
        raw_alias = Enum.at(match, 2)
        add_table_ref(t_acc, a_acc, tbl, raw_alias)
      end)

    # Also capture simple comma-joined tables inside FROM ... (until next clause keyword)
    from_block_regex = ~r/\bFROM\s+([^;]+?)(?=\b(?:WHERE|GROUP|ORDER|HAVING|LIMIT|UNION|SET|$))/is

    Regex.scan(from_block_regex, sql)
    |> Enum.reduce({tbls, aliases}, fn [_, block], acc ->
      block
      |> String.split(",")
      |> Enum.drop(1)
      |> Enum.reduce(acc, fn part, {t_acc, a_acc} ->
        case Regex.run(
               ~r/^\s*(?:[a-zA-Z0-9_"]+\.)?("?[a-zA-Z0-9_]+"?)(?:\s+(?:AS\s+)?([a-zA-Z_][a-zA-Z0-9_]*))?/i,
               part
             ) do
          [_, raw_tbl | rest] ->
            tbl = String.replace(raw_tbl, "\"", "")
            raw_alias = List.first(rest)
            add_table_ref(t_acc, a_acc, tbl, raw_alias)

          _ ->
            {t_acc, a_acc}
        end
      end)
    end)
  end

  def extract_table_refs(_), do: {[], %{}}

  defp add_table_ref(tbls, aliases, "", _raw_alias), do: {tbls, aliases}

  defp add_table_ref(tbls, aliases, tbl, raw_alias) do
    up_tbl = String.upcase(tbl)

    if MapSet.member?(@non_alias_keywords, up_tbl) do
      {tbls, aliases}
    else
      new_tbls = if tbl in tbls, do: tbls, else: tbls ++ [tbl]

      new_aliases =
        if is_binary(raw_alias) and raw_alias != "" and
             not MapSet.member?(@non_alias_keywords, String.upcase(raw_alias)) do
          Map.put(aliases, String.downcase(raw_alias), tbl)
        else
          aliases
        end

      {new_tbls, new_aliases}
    end
  end

  @doc """
  Generates a short non-conflicting alias for `table_name` (e.g. `users` -> `u`,
  `order_items` -> `oi`, or `u2` if `u` is already taken).
  """
  @spec suggest_alias(String.t(), [String.t()]) :: String.t()
  def suggest_alias(table_name, used_aliases \\ []) when is_binary(table_name) do
    used = MapSet.new(used_aliases, &String.downcase(to_string(&1)))

    parts =
      table_name
      |> String.split(~r/[^a-zA-Z0-9]+/, trim: true)
      |> Enum.reject(&(&1 == ""))

    base =
      case parts do
        [] -> "t"
        [single] -> String.slice(String.downcase(single), 0, 1)
        many -> Enum.map_join(many, "", &String.slice(String.downcase(&1), 0, 1))
      end

    if not MapSet.member?(used, base) and
         not MapSet.member?(@non_alias_keywords, String.upcase(base)) do
      base
    else
      two_char = String.slice(String.downcase(table_name), 0, 2)

      if String.length(two_char) == 2 and not MapSet.member?(used, two_char) do
        two_char
      else
        Stream.iterate(2, &(&1 + 1))
        |> Enum.find_value(fn n ->
          candidate = "#{base}#{n}"
          if not MapSet.member?(used, candidate), do: candidate
        end)
      end
    end
  end

  @doc """
  Determines the expected SQL completion context immediately before `prefix`
  (`:table`, `:column`, or `:general`).
  """
  @spec suggest_type(String.t(), String.t()) :: :table | :column | :general
  def suggest_type(before_cursor, prefix \\ "") when is_binary(before_cursor) do
    stripped =
      if prefix == "" do
        String.trim_trailing(before_cursor)
      else
        before_cursor
        |> String.trim_trailing(prefix)
        |> String.trim_trailing()
      end

    cond do
      stripped == "" ->
        :general

      Regex.match?(
        ~r/\b(?:FROM|JOIN|UPDATE|INTO|TABLE)\s*(?:,\s*(?:[a-zA-Z0-9_"]+\.)?[a-zA-Z0-9_"]+(?:\s+(?:AS\s+)?[a-zA-Z0-9_]+)?\s*,\s*)?$/i,
        stripped
      ) ->
        :table

      Regex.match?(~r/,\s*$/i, stripped) and inside_from_clause?(stripped) ->
        :table

      Regex.match?(
        ~r/(?:\b(?:SELECT|WHERE|ON|AND|OR|NOT|SET|HAVING|WHEN|CASE|GROUP\s+BY|ORDER\s+BY)|[=(,+\-\*\/<>!]|\!=|<>)\s*$/i,
        stripped
      ) ->
        :column

      true ->
        :general
    end
  end

  defp inside_from_clause?(text) do
    tokens =
      Regex.scan(~r/\b[A-Z_]+\b/i, text)
      |> List.flatten()
      |> Enum.map(&String.upcase/1)
      |> Enum.reverse()

    Enum.find_value(tokens, false, fn tok ->
      cond do
        tok in @table_clause_keywords -> true
        tok in @column_clause_keywords -> false
        true -> nil
      end
    end) || false
  end

  @doc """
  Generates context-aware suggestions for `prefix` (or empty prefix after clause keyword/dot).

  Options:
  - `:sidebar_nodes` - sidebar tree nodes containing schemas/tables/views
  - `:table_columns` - `%{table_name => [column_name]}`
  - `:sql` - full editor SQL text
  - `:cursor` - `{row, col}` for statement & clause scoping
  - `:allow_empty_prefix` - allow suggestions right after a clause keyword or `.`
  """
  @spec suggestions(String.t(), keyword()) :: [suggestion()]
  def suggestions(prefix, opts \\ []) when is_binary(prefix) do
    clean_prefix = String.trim(prefix)
    sidebar_nodes = Keyword.get(opts, :sidebar_nodes, [])
    table_columns = Keyword.get(opts, :table_columns, %{})
    full_sql = Keyword.get(opts, :sql, "")
    cursor = Keyword.get(opts, :cursor)
    allow_empty? = Keyword.get(opts, :allow_empty_prefix, false)

    {stmt_sql, before_cursor} =
      if is_tuple(cursor) and full_sql != "" do
        statement_at_cursor(full_sql, cursor)
      else
        {full_sql, full_sql}
      end

    tables = (extract_tables(sidebar_nodes) ++ extract_cte_names(stmt_sql)) |> Enum.uniq()

    cond do
      String.contains?(clean_prefix, ".") ->
        [qualifier, col_prefix] = String.split(clean_prefix, ".", parts: 2)

        if qualifier != "" do
          dot_suggestions(qualifier, col_prefix, tables, table_columns, stmt_sql)
        else
          []
        end

      clean_prefix == "" and not allow_empty? ->
        []

      true ->
        clause = suggest_type(before_cursor, prefix)
        clause_suggestions(clause, clean_prefix, tables, table_columns, stmt_sql)
    end
    |> Enum.uniq_by(fn s -> {s.type, s.insert_text} end)
    |> Enum.take(12)
  end

  defp extract_cte_names(sql) when is_binary(sql) do
    Regex.scan(~r/\bWITH\s+([a-zA-Z_][a-zA-Z0-9_]*)\s+AS\s*\(/i, sql)
    |> Enum.map(&Enum.at(&1, 1))
    |> Kernel.++(
      Regex.scan(~r/,\s*([a-zA-Z_][a-zA-Z0-9_]*)\s+AS\s*\(/i, sql)
      |> Enum.map(&Enum.at(&1, 1))
    )
    |> Enum.reject(&is_nil/1)
  end

  defp extract_cte_names(_), do: []

  defp dot_suggestions(qualifier, col_prefix, tables, table_columns, stmt_sql) do
    {_ref_tables, aliases} = extract_table_refs(stmt_sql)
    q_down = String.downcase(qualifier)
    col_down = String.downcase(col_prefix)

    resolved_table =
      Map.get(aliases, q_down) ||
        Enum.find(Map.keys(table_columns), &(String.downcase(&1) == q_down))

    col_matches =
      case resolved_table && lookup_table_columns(table_columns, resolved_table) do
        cols when is_list(cols) and cols != [] ->
          cols
          |> fuzzy_filter_and_rank(col_down)
          |> Enum.map(fn col ->
            %{
              label: "#{qualifier}.#{col}",
              type: :column,
              insert_text: "#{qualifier}.#{col}",
              detail: "#{resolved_table} → #{col}"
            }
          end)

        _ ->
          []
      end

    if col_matches != [] do
      col_matches
    else
      tables
      |> fuzzy_filter_and_rank(col_down)
      |> Enum.map(fn tbl ->
        %{
          label: "#{qualifier}.#{tbl}",
          type: :table,
          insert_text: "#{qualifier}.#{tbl}",
          detail: "table"
        }
      end)
    end
  end

  defp clause_suggestions(:table, clean_prefix, tables, _table_columns, stmt_sql) do
    {_ref_tables, aliases} = extract_table_refs(stmt_sql)
    used_aliases = Map.keys(aliases)
    down_prefix = String.downcase(clean_prefix)

    tables
    |> fuzzy_filter_and_rank(down_prefix)
    |> Enum.flat_map(fn tbl ->
      alias_name = suggest_alias(tbl, used_aliases)

      [
        %{
          label: "#{tbl} #{alias_name}",
          type: :table,
          insert_text: "#{tbl} #{alias_name}",
          detail: "alias #{alias_name}"
        },
        %{
          label: tbl,
          type: :table,
          insert_text: tbl,
          detail: "table"
        }
      ]
    end)
  end

  defp clause_suggestions(:column, clean_prefix, tables, table_columns, stmt_sql) do
    {ref_tables, aliases} = extract_table_refs(stmt_sql)
    down_prefix = String.downcase(clean_prefix)
    alias_by_table = invert_aliases(aliases)
    multi_table? = length(ref_tables) > 1

    scoped_entries =
      if ref_tables != [] do
        Enum.flat_map(ref_tables, fn tbl ->
          alias_name = Map.get(alias_by_table, String.downcase(tbl))

          lookup_table_columns(table_columns, tbl)
          |> Enum.map(fn col -> {tbl, alias_name, col} end)
        end)
      else
        table_columns
        |> Enum.flat_map(fn {tbl, cols} -> Enum.map(cols, &{tbl, nil, &1}) end)
      end

    column_matches =
      scoped_entries
      |> rank_column_entries(down_prefix)
      |> Enum.map(fn {tbl, alias_name, col} ->
        insert_val =
          cond do
            is_binary(alias_name) and alias_name != "" -> "#{alias_name}.#{col}"
            multi_table? -> "#{tbl}.#{col}"
            true -> col
          end

        %{
          label: insert_val,
          type: :column,
          insert_text: insert_val,
          detail: "#{tbl} → #{col}"
        }
      end)

    if clean_prefix == "" do
      column_matches
    else
      keyword_matches = match_keywords(clean_prefix)
      table_matches = match_tables(tables, down_prefix)
      column_matches ++ keyword_matches ++ table_matches
    end
  end

  defp clause_suggestions(:general, "", _tables, _table_columns, _stmt_sql), do: []

  defp clause_suggestions(:general, clean_prefix, tables, table_columns, stmt_sql) do
    down_prefix = String.downcase(clean_prefix)
    keyword_matches = match_keywords(clean_prefix)
    table_matches = match_tables(tables, down_prefix)
    col_matches = clause_suggestions(:column, clean_prefix, tables, table_columns, stmt_sql)

    keyword_matches ++ table_matches ++ col_matches
  end

  defp match_keywords(clean_prefix) do
    up_prefix = String.upcase(clean_prefix)

    @keywords
    |> Enum.filter(&String.starts_with?(String.upcase(&1), up_prefix))
    |> Enum.map(&%{label: &1, type: :keyword, insert_text: &1, detail: "keyword"})
  end

  defp match_tables(tables, down_prefix) do
    tables
    |> fuzzy_filter_and_rank(down_prefix)
    |> Enum.map(&%{label: &1, type: :table, insert_text: &1, detail: "table"})
  end

  defp invert_aliases(aliases) do
    Enum.reduce(aliases, %{}, fn {alias_name, tbl}, acc ->
      Map.put_new(acc, String.downcase(tbl), alias_name)
    end)
  end

  defp rank_column_entries(entries, ""), do: entries

  defp rank_column_entries(entries, down_prefix) do
    entries
    |> Enum.flat_map(fn {_tbl, _alias, col} = entry ->
      case fuzzy_score(String.downcase(col), down_prefix) do
        nil -> []
        score -> [{score, entry}]
      end
    end)
    |> Enum.sort_by(fn {score, {_tbl, _alias, col}} -> {score, String.length(col), col} end)
    |> Enum.map(&elem(&1, 1))
  end

  defp lookup_table_columns(table_columns, target) when is_map(table_columns) do
    t_down = String.downcase(to_string(target))

    Map.get(table_columns, target) ||
      Enum.find_value(table_columns, [], fn {k, v} ->
        if String.downcase(to_string(k)) == t_down, do: v
      end)
  end

  defp lookup_table_columns(_, _), do: []

  defp fuzzy_filter_and_rank(items, ""), do: items

  defp fuzzy_filter_and_rank(items, down_prefix) do
    items
    |> Enum.flat_map(fn item ->
      case fuzzy_score(String.downcase(item), down_prefix) do
        nil -> []
        score -> [{score, item}]
      end
    end)
    |> Enum.sort_by(fn {score, item} -> {score, String.length(item), item} end)
    |> Enum.map(&elem(&1, 1))
  end

  defp fuzzy_score(_candidate, ""), do: 0

  defp fuzzy_score(candidate, query) do
    cond do
      String.starts_with?(candidate, query) -> 0
      String.contains?(candidate, query) -> 1
      subsequence?(candidate, query) -> 2
      true -> nil
    end
  end

  defp subsequence?(candidate, query) do
    q_chars = String.graphemes(query)
    c_chars = String.graphemes(candidate)
    match_subseq?(c_chars, q_chars)
  end

  defp match_subseq?(_c, []), do: true
  defp match_subseq?([], _q), do: false

  defp match_subseq?([c | cs], [q | qs]) do
    if c == q, do: match_subseq?(cs, qs), else: match_subseq?(cs, [q | qs])
  end

  @doc """
  Replaces `prefix` before `{row, col}` cursor with `suggestion.insert_text`.
  Returns `{updated_content, new_cursor}`.
  """
  @spec apply_completion(
          String.t(),
          {non_neg_integer(), non_neg_integer()},
          suggestion(),
          String.t()
        ) ::
          {String.t(), {non_neg_integer(), non_neg_integer()}}
  def apply_completion(content, {row, col}, suggestion, prefix) do
    lines = String.split(content, "\n")
    line_idx = max(0, min(length(lines) - 1, row))
    line = Enum.at(lines, line_idx, "")
    col = max(0, min(String.length(line), col))

    prefix_len = String.length(prefix)
    start_c = max(0, col - prefix_len)

    before_word = String.slice(line, 0, start_c)
    after_word = String.slice(line, col..-1//1)

    ins_text = suggestion.insert_text
    new_line = before_word <> ins_text <> after_word
    updated_lines = List.replace_at(lines, line_idx, new_line)

    new_col = String.length(before_word <> ins_text)
    {Enum.join(updated_lines, "\n"), {row, new_col}}
  end
end
