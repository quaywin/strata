defmodule Strata.UI.Components.SQLLinter do
  @moduledoc """
  Lightweight, zero-latency pure Elixir linter for SQL queries in the editor.
  Checks structural balance (quotes, parentheses), statement-scoped table/alias
  column references against cached schemas, and destructive statements missing `WHERE`.
  """

  alias Strata.UI.Components.SQLCompleter

  @type diagnostic :: %{
          severity: :error | :warning,
          line: non_neg_integer(),
          col: non_neg_integer(),
          message: String.t(),
          token: String.t() | nil
        }

  @sql_reserved_identifiers MapSet.new(~w(
    SELECT FROM WHERE INSERT INTO UPDATE DELETE JOIN INNER LEFT RIGHT OUTER CROSS FULL
    NATURAL USING ON GROUP BY ORDER HAVING LIMIT OFFSET AS AND OR NOT IN IS NULL
    TRUE FALSE LIKE ILIKE SIMILAR BETWEEN EXISTS CASE WHEN THEN ELSE END DISTINCT ALL
    ANY SOME UNION EXCEPT INTERSECT WITH RECURSIVE VALUES SET RETURNING ASC DESC
    NULLS FIRST LAST COUNT SUM AVG MIN MAX COALESCE NULLIF CAST CURRENT_TIMESTAMP
    CURRENT_DATE NOW LOWER UPPER TRIM LENGTH SUBSTRING
  ))

  @doc """
  Checks `sql` and returns a list of diagnostics sorted by line and column.
  """
  @spec check(String.t(), keyword()) :: [diagnostic()]
  def check(sql, opts \\ [])

  def check(sql, opts) when is_binary(sql) do
    trimmed = String.trim(sql)

    if trimmed == "" do
      []
    else
      table_columns = Keyword.get(opts, :table_columns, %{})
      sidebar_nodes = Keyword.get(opts, :sidebar_nodes, [])
      known_tables = SQLCompleter.extract_tables(sidebar_nodes)

      balance_diags = check_balance(sql)
      stmt_diags = check_statements(sql, table_columns, known_tables)

      (balance_diags ++ stmt_diags)
      |> Enum.uniq_by(&{&1.severity, &1.line, &1.message})
      |> Enum.sort_by(&{&1.line, &1.col})
    end
  end

  def check(_, _), do: []

  defp check_balance(sql) do
    {paren_stack, quote_open, line, col} =
      scan_balance(sql, {[], nil, 0, 0})

    quote_diags =
      case quote_open do
        {q_line, q_col} ->
          [
            %{
              severity: :error,
              line: q_line,
              col: q_col,
              message: "Unclosed string literal (')",
              token: "'"
            }
          ]

        nil ->
          []
      end

    unclosed_paren_diags =
      Enum.map(paren_stack, fn
        {:unmatched_close, l, c} ->
          %{
            severity: :error,
            line: l,
            col: c,
            message: "Unexpected closing parenthesis ')'",
            token: ")"
          }

        {l, c} ->
          %{
            severity: :error,
            line: l,
            col: c,
            message: "Unclosed parenthesis '('",
            token: "("
          }
      end)

    _ = {line, col}
    quote_diags ++ unclosed_paren_diags
  end

  defp scan_balance(sql, init) do
    len = String.length(sql)
    do_scan_balance(sql, 0, len, init, false, false)
  end

  defp do_scan_balance(_sql, idx, len, state, _in_comment?, _in_block?) when idx >= len, do: state

  defp do_scan_balance(sql, idx, len, {stack, quote_pos, l, c}, true, false) do
    ch = String.at(sql, idx)

    if ch == "\n" do
      do_scan_balance(sql, idx + 1, len, {stack, quote_pos, l + 1, 0}, false, false)
    else
      do_scan_balance(sql, idx + 1, len, {stack, quote_pos, l, c + 1}, true, false)
    end
  end

  defp do_scan_balance(sql, idx, len, {stack, quote_pos, l, c}, false, true) do
    ch = String.at(sql, idx)
    nxt = String.at(sql, idx + 1)

    cond do
      ch == "*" and nxt == "/" ->
        do_scan_balance(sql, idx + 2, len, {stack, quote_pos, l, c + 2}, false, false)

      ch == "\n" ->
        do_scan_balance(sql, idx + 1, len, {stack, quote_pos, l + 1, 0}, false, true)

      true ->
        do_scan_balance(sql, idx + 1, len, {stack, quote_pos, l, c + 1}, false, true)
    end
  end

  defp do_scan_balance(sql, idx, len, {stack, {ql, qc}, l, c}, false, false) do
    ch = String.at(sql, idx)

    cond do
      ch == "'" and String.at(sql, idx + 1) == "'" ->
        do_scan_balance(sql, idx + 2, len, {stack, {ql, qc}, l, c + 2}, false, false)

      ch == "'" ->
        do_scan_balance(sql, idx + 1, len, {stack, nil, l, c + 1}, false, false)

      ch == "\n" ->
        do_scan_balance(sql, idx + 1, len, {stack, {ql, qc}, l + 1, 0}, false, false)

      true ->
        do_scan_balance(sql, idx + 1, len, {stack, {ql, qc}, l, c + 1}, false, false)
    end
  end

  defp do_scan_balance(sql, idx, len, {stack, nil, l, c}, false, false) do
    ch = String.at(sql, idx)
    nxt = String.at(sql, idx + 1)

    cond do
      ch == "-" and nxt == "-" ->
        do_scan_balance(sql, idx + 2, len, {stack, nil, l, c + 2}, true, false)

      ch == "/" and nxt == "*" ->
        do_scan_balance(sql, idx + 2, len, {stack, nil, l, c + 2}, false, true)

      ch == "'" ->
        do_scan_balance(sql, idx + 1, len, {stack, {l, c}, l, c + 1}, false, false)

      ch == "(" ->
        do_scan_balance(sql, idx + 1, len, {[{l, c} | stack], nil, l, c + 1}, false, false)

      ch == ")" ->
        new_stack =
          case stack do
            [{_ol, _oc} | rest] -> rest
            other -> [{:unmatched_close, l, c} | other]
          end

        do_scan_balance(sql, idx + 1, len, {new_stack, nil, l, c + 1}, false, false)

      ch == "\n" ->
        do_scan_balance(sql, idx + 1, len, {stack, nil, l + 1, 0}, false, false)

      true ->
        do_scan_balance(sql, idx + 1, len, {stack, nil, l, c + 1}, false, false)
    end
  end

  defp check_statements(sql, table_columns, known_tables) do
    split_statements_with_lines(sql)
    |> Enum.flat_map(fn {stmt, base_line} ->
      check_single_statement(stmt, base_line, table_columns, known_tables)
    end)
  end

  defp split_statements_with_lines(sql) do
    {rev_stmts, cur_chars, start_line, _cur_line, _in_q, _in_c} =
      sql
      |> String.graphemes()
      |> Enum.with_index()
      |> Enum.reduce({[], [], 0, 0, false, false}, fn {ch, idx},
                                                      {acc, buf, s_line, line, in_q?, in_c?} ->
        cond do
          in_c? and ch == "\n" ->
            {acc, [ch | buf], s_line, line + 1, in_q?, false}

          in_c? ->
            {acc, [ch | buf], s_line, line, in_q?, true}

          not in_q? and ch == "-" and String.at(sql, idx + 1) == "-" ->
            {acc, [ch | buf], s_line, line, false, true}

          ch == "'" ->
            {acc, [ch | buf], s_line, line, not in_q?, false}

          not in_q? and ch == ";" ->
            stmt = buf |> Enum.reverse() |> Enum.join()
            {[{stmt, s_line} | acc], [], line, line, false, false}

          ch == "\n" ->
            {acc, [ch | buf], s_line, line + 1, in_q?, false}

          true ->
            {acc, [ch | buf], s_line, line, in_q?, false}
        end
      end)

    last_stmt = cur_chars |> Enum.reverse() |> Enum.join()
    Enum.reverse([{last_stmt, start_line} | rev_stmts])
  end

  defp check_single_statement(stmt, base_line, table_columns, known_tables) do
    clean = strip_strings_and_comments(stmt)
    trimmed = String.trim(clean)

    if trimmed == "" do
      []
    else
      {ref_tables, aliases} = SQLCompleter.extract_table_refs(clean)
      safety_diags = check_destructive_missing_where(trimmed, base_line)

      qualified_diags =
        check_qualified_columns(
          clean,
          base_line,
          ref_tables,
          aliases,
          table_columns,
          known_tables
        )

      unqualified_diags =
        check_unqualified_where_columns(clean, base_line, ref_tables, table_columns)

      safety_diags ++ qualified_diags ++ unqualified_diags
    end
  end

  defp check_destructive_missing_where(trimmed, base_line) do
    cond do
      Regex.match?(~r/^\s*DELETE\s+FROM\s+\S+/i, trimmed) and
          not Regex.match?(~r/\bWHERE\b/i, trimmed) ->
        [
          %{
            severity: :warning,
            line: base_line,
            col: 0,
            message: "DELETE without WHERE affects all rows",
            token: "DELETE"
          }
        ]

      Regex.match?(~r/^\s*UPDATE\s+\S+\s+SET\b/i, trimmed) and
          not Regex.match?(~r/\bWHERE\b/i, trimmed) ->
        [
          %{
            severity: :warning,
            line: base_line,
            col: 0,
            message: "UPDATE without WHERE modifies all rows",
            token: "UPDATE"
          }
        ]

      true ->
        []
    end
  end

  defp check_qualified_columns(clean, base_line, ref_tables, aliases, table_columns, known_tables) do
    if ref_tables == [] do
      []
    else
      ref_set = MapSet.new(ref_tables, &String.downcase/1)
      known_set = MapSet.new(known_tables, &String.downcase/1)

      # Skip FROM schema.table / JOIN schema.table qualifiers by ignoring tokens immediately after FROM/JOIN/INTO/UPDATE
      Regex.scan(~r/\b([a-zA-Z_][a-zA-Z0-9_]*)\.([a-zA-Z_][a-zA-Z0-9_]*)\b/, clean)
      |> Enum.flat_map(fn [full, qual, col] ->
        q_down = String.downcase(qual)
        resolved = Map.get(aliases, q_down) || find_ci(ref_tables, q_down)
        line_offset = line_of_match(clean, full)

        cond do
          resolved == nil and MapSet.member?(known_set, String.downcase(col)) ->
            # Likely schema.table reference
            []

          resolved == nil and not MapSet.member?(ref_set, q_down) ->
            [
              %{
                severity: :error,
                line: base_line + line_offset,
                col: 0,
                message: "Unknown table/alias '#{qual}'",
                token: full
              }
            ]

          resolved != nil ->
            case lookup_ci_columns(table_columns, resolved) do
              cols when is_list(cols) and cols != [] ->
                col_down = String.downcase(col)

                if Enum.any?(cols, &(String.downcase(&1) == col_down)) do
                  []
                else
                  [
                    %{
                      severity: :error,
                      line: base_line + line_offset,
                      col: 0,
                      message: "Column '#{col}' not found in '#{resolved}'",
                      token: full
                    }
                  ]
                end

              _ ->
                []
            end

          true ->
            []
        end
      end)
    end
  end

  defp check_unqualified_where_columns(clean, base_line, ref_tables, table_columns) do
    cached_ref_cols =
      ref_tables
      |> Enum.map(&lookup_ci_columns(table_columns, &1))

    # Only check unqualified columns when ALL referenced tables have cached columns
    if ref_tables != [] and Enum.all?(cached_ref_cols, &(&1 != [])) do
      all_cols = cached_ref_cols |> List.flatten() |> MapSet.new(&String.downcase/1)

      case Regex.run(~r/\bWHERE\b(.*)$/is, clean) do
        [_, where_body] ->
          # Strip qualified q.col references first
          body_no_qual =
            Regex.replace(~r/\b[a-zA-Z_][a-zA-Z0-9_]*\.[a-zA-Z_*][a-zA-Z0-9_]*\b/, where_body, "")

          # Ignore function calls like COUNT(x) -> keep identifiers inside parens, drop function names
          body_no_funcs = Regex.replace(~r/\b([a-zA-Z_][a-zA-Z0-9_]*)\s*\(/, body_no_qual, "(")

          Regex.scan(~r/\b([a-zA-Z_][a-zA-Z0-9_]*)\b/, body_no_funcs)
          |> Enum.flat_map(fn [_, ident] ->
            up = String.upcase(ident)
            down = String.downcase(ident)

            if MapSet.member?(@sql_reserved_identifiers, up) or MapSet.member?(all_cols, down) do
              []
            else
              [
                %{
                  severity: :warning,
                  line: base_line + line_of_match(clean, ident),
                  col: 0,
                  message: "Unknown column '#{ident}'",
                  token: ident
                }
              ]
            end
          end)

        _ ->
          []
      end
    else
      []
    end
  end

  defp line_of_match(text, token) do
    case :binary.match(text, token) do
      {pos, _} ->
        text
        |> binary_part(0, pos)
        |> String.split("\n")
        |> length()
        |> Kernel.-(1)

      :nomatch ->
        0
    end
  end

  defp strip_strings_and_comments(sql) do
    sql
    |> String.replace(~r/--[^\n]*/, "")
    |> String.replace(~r/\/\*[\s\S]*?\*\//, "")
    |> String.replace(~r/'(?:''|[^'])*'/, "''")
  end

  defp find_ci(list, down) do
    Enum.find(list, &(String.downcase(&1) == down))
  end

  defp lookup_ci_columns(table_columns, target) do
    t_down = String.downcase(target)

    Map.get(table_columns, target) ||
      Enum.find_value(table_columns, [], fn {k, v} ->
        if String.downcase(to_string(k)) == t_down, do: v
      end)
  end
end
