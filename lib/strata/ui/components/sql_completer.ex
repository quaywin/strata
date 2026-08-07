defmodule Strata.UI.Components.SQLCompleter do
  @moduledoc """
  Autocomplete engine for SQL keywords, schema table names, and column names.
  Provides context-aware suggestions and prefix replacement for the SQL Query Editor.
  """

  @keywords ~w(
    SELECT FROM WHERE INSERT INTO UPDATE DELETE JOIN INNER LEFT RIGHT OUTER CROSS FULL
    ON GROUP BY ORDER HAVING LIMIT OFFSET AS AND OR NOT IN IS NULL LIKE ILIKE CREATE
    TABLE DROP ALTER INDEX PRIMARY KEY FOREIGN REFERENCES DEFAULT VALUES SET WITH
    UNION ALL CASE WHEN THEN ELSE END ASC DESC COUNT SUM AVG MIN MAX DISTINCT TRUE FALSE
    BOOLEAN INTEGER VARCHAR TEXT TIMESTAMP DATE
  )

  @type suggestion :: %{
          label: String.t(),
          type: :keyword | :table | :column,
          insert_text: String.t()
        }

  @doc """
  Extracts current prefix word immediately preceding cursor `{row, col}`.
  Returns `{prefix_word, start_col}`.
  """
  @spec extract_prefix(String.t(), {non_neg_integer(), non_neg_integer()}) :: {String.t(), non_neg_integer()}
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
  Extracts table names from current sidebar tree nodes.
  """
  @spec extract_tables([map()]) :: [String.t()]
  def extract_tables(nodes) when is_list(nodes) do
    flat = Strata.UI.Components.Sidebar.flatten_visible_nodes(nodes)

    flat
    |> Enum.filter(&(&1.type in [:table, :view]))
    |> Enum.map(& &1.label)
    |> Enum.uniq()
  end

  @doc """
  Generates list of matching suggestions for given `prefix` word.
  """
  @spec suggestions(String.t(), keyword()) :: [suggestion()]
  def suggestions(prefix, opts \\ []) when is_binary(prefix) do
    clean_prefix = String.trim(prefix)

    if String.length(clean_prefix) < 1 do
      []
    else
      up_prefix = String.upcase(clean_prefix)
      down_prefix = String.downcase(clean_prefix)

      # 1. Match SQL Keywords
      keyword_matches =
        @keywords
        |> Enum.filter(&String.starts_with?(String.upcase(&1), up_prefix))
        |> Enum.map(fn kw ->
          %{label: kw, type: :keyword, insert_text: kw}
        end)

      # 2. Match Schema Tables
      sidebar_nodes = Keyword.get(opts, :sidebar_nodes, [])
      tables = extract_tables(sidebar_nodes)

      table_matches =
        tables
        |> Enum.filter(&String.starts_with?(String.downcase(&1), down_prefix))
        |> Enum.map(fn tbl ->
          %{label: tbl, type: :table, insert_text: tbl}
        end)

      # Limit total suggestions to top 10
      Enum.take(keyword_matches ++ table_matches, 10)
    end
  end

  @doc """
  Replaces `prefix` before `{row, col}` cursor with `suggestion.insert_text`.
  Returns `{updated_content, new_cursor}`.
  """
  @spec apply_completion(String.t(), {non_neg_integer(), non_neg_integer()}, suggestion(), String.t()) ::
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
