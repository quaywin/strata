defmodule Strata.QueryBuilder do
  @moduledoc """
  Generates parameterized UPDATE, INSERT, and DELETE SQL statements from staged
  DataGrid changes for PostgreSQL (`$1`, `$2`), MySQL (`?`), and SQLite (`?`).
  """

  alias Strata.Adapter

  @type statement :: {String.t(), [term()]}

  @doc """
  Coerces an edited inline input string back toward the original cell's type
  where safe (`integer`, `float`, `boolean`), leaving strings and explicit `nil`
  unchanged.
  """
  @spec coerce_value(term(), term()) :: term()
  def coerce_value(nil, _orig), do: nil

  def coerce_value(val, orig) when is_binary(val) do
    cond do
      is_integer(orig) ->
        case Integer.parse(String.trim(val)) do
          {int, ""} -> int
          _ -> val
        end

      is_float(orig) ->
        case Float.parse(String.trim(val)) do
          {flt, ""} -> flt
          _ -> val
        end

      is_boolean(orig) ->
        case String.downcase(String.trim(val)) do
          "true" -> true
          "1" -> true
          "false" -> false
          "0" -> false
          _ -> val
        end

      true ->
        val
    end
  end

  def coerce_value(val, _orig), do: val

  @doc """
  Builds a parameterized `UPDATE` statement for a single modified row.
  """
  @spec build_update(
          atom() | String.t(),
          String.t(),
          [String.t()],
          [term()],
          %{non_neg_integer() => term()},
          [String.t()]
        ) :: {:ok, statement()} | {:error, term()}
  def build_update(_driver, _table, _columns, _orig_row, col_edits, _pk_cols)
      when map_size(col_edits) == 0 do
    {:error, :no_edits}
  end

  def build_update(driver, qualified_table, columns, orig_row, col_edits, pk_cols) do
    sorted_edits = col_edits |> Enum.sort_by(fn {c_idx, _val} -> c_idx end)

    {set_clauses, set_params, next_idx} =
      Enum.reduce(sorted_edits, {[], [], 1}, fn {c_idx, new_val}, {clauses, params, idx} ->
        col_name = Enum.at(columns, c_idx)
        q_col = Adapter.quote_identifier(driver, col_name)
        {clauses ++ ["#{q_col} = #{placeholder(driver, idx)}"], params ++ [new_val], idx + 1}
      end)

    case build_where(driver, columns, orig_row, pk_cols, next_idx) do
      {:ok, where_sql, where_params} ->
        sql =
          "UPDATE #{qualified_table} SET #{Enum.join(set_clauses, ", ")} WHERE #{where_sql};"

        {:ok, {sql, set_params ++ where_params}}

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Builds a parameterized `INSERT` statement for a newly staged row.
  Omits `nil` columns so auto-increment / DEFAULT values apply cleanly; falls back
  to `DEFAULT VALUES` (or `() VALUES ()` on MySQL) if all cells are `nil`.
  """
  @spec build_insert(atom() | String.t(), String.t(), [String.t()], [term()]) ::
          {:ok, statement()} | {:error, term()}
  def build_insert(_driver, _table, [], _new_row), do: {:error, :no_columns}

  def build_insert(driver, qualified_table, columns, new_row) do
    non_nil_pairs =
      columns
      |> Enum.zip(new_row)
      |> Enum.reject(fn {_col, val} -> is_nil(val) end)

    if non_nil_pairs == [] do
      sql =
        if Adapter.normalize_driver(driver) == :mysql do
          "INSERT INTO #{qualified_table} () VALUES ();"
        else
          "INSERT INTO #{qualified_table} DEFAULT VALUES;"
        end

      {:ok, {sql, []}}
    else
      {cols_sql, placeholders, params} =
        non_nil_pairs
        |> Enum.with_index(1)
        |> Enum.reduce({[], [], []}, fn {{col, val}, idx}, {c_acc, p_acc, v_acc} ->
          q_col = Adapter.quote_identifier(driver, col)
          {c_acc ++ [q_col], p_acc ++ [placeholder(driver, idx)], v_acc ++ [val]}
        end)

      sql =
        "INSERT INTO #{qualified_table} (#{Enum.join(cols_sql, ", ")}) VALUES (#{Enum.join(placeholders, ", ")});"

      {:ok, {sql, params}}
    end
  end

  @doc """
  Builds a parameterized `DELETE` statement for a row marked for deletion.
  Uses `pk_cols` when available, otherwise matches all columns of the original row.
  """
  @spec build_delete(atom() | String.t(), String.t(), [String.t()], [term()], [String.t()]) ::
          {:ok, statement()} | {:error, term()}
  def build_delete(driver, qualified_table, columns, orig_row, pk_cols) do
    case build_where(driver, columns, orig_row, pk_cols, 1) do
      {:ok, where_sql, where_params} ->
        {:ok, {"DELETE FROM #{qualified_table} WHERE #{where_sql};", where_params}}

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Compiles all staged edits, inserts, and deletes into an ordered list of
  parameterized `{sql, params}` statements suitable for transaction execution.
  Rows marked for deletion skip any staged cell edits on that same row.
  """
  @spec build_batch(atom() | String.t(), String.t(), [String.t()], [[term()]], keyword()) ::
          {:ok, [statement()]} | {:error, term()}
  def build_batch(driver, qualified_table, columns, rows, opts \\ []) do
    pending_edits = Keyword.get(opts, :pending_edits, %{})
    pending_inserts = Keyword.get(opts, :pending_inserts, [])
    pending_deletes = Keyword.get(opts, :pending_deletes, MapSet.new())
    pk_cols = Keyword.get(opts, :primary_keys, [])

    edits_by_row =
      pending_edits
      |> Enum.reject(fn {{r_idx, _c_idx}, _edit} -> MapSet.member?(pending_deletes, r_idx) end)
      |> Enum.group_by(
        fn {{r_idx, _c_idx}, _edit} -> r_idx end,
        fn {{_r_idx, c_idx}, edit} -> {c_idx, edit.new} end
      )
      |> Enum.sort_by(fn {r_idx, _} -> r_idx end)

    update_results =
      Enum.map(edits_by_row, fn {r_idx, col_pairs} ->
        orig_row = Enum.at(rows, r_idx, [])
        build_update(driver, qualified_table, columns, orig_row, Map.new(col_pairs), pk_cols)
      end)

    insert_results =
      Enum.map(pending_inserts, fn new_row ->
        build_insert(driver, qualified_table, columns, new_row)
      end)

    delete_results =
      pending_deletes
      |> Enum.sort()
      |> Enum.map(fn r_idx ->
        orig_row = Enum.at(rows, r_idx, [])
        build_delete(driver, qualified_table, columns, orig_row, pk_cols)
      end)

    all = update_results ++ insert_results ++ delete_results

    case Enum.find(all, &match?({:error, _}, &1)) do
      {:error, reason} -> {:error, reason}
      nil -> {:ok, Enum.map(all, fn {:ok, stmt} -> stmt end)}
    end
  end

  @filter_ops [:contains, :starts_with, :=, :!=, :>, :<, :>=, :<=, :is_null, :is_not_null]

  @doc """
  Returns the ordered list of structured filter operators supported by the Filter Bar.
  """
  @spec filter_operators() :: [atom()]
  def filter_operators, do: @filter_ops

  @doc """
  Returns the human-readable UI label for a filter operator atom.
  """
  @spec operator_label(atom()) :: String.t()
  def operator_label(:contains), do: "contains"
  def operator_label(:starts_with), do: "starts with"
  def operator_label(:=), do: "="
  def operator_label(:!=), do: "!="
  def operator_label(:>), do: ">"
  def operator_label(:<), do: "<"
  def operator_label(:>=), do: ">="
  def operator_label(:<=), do: "<="
  def operator_label(:is_null), do: "IS NULL"
  def operator_label(:is_not_null), do: "IS NOT NULL"
  def operator_label(other), do: to_string(other)

  @doc """
  Builds a parameterized `SELECT * FROM ... WHERE ...` query from either a visual
  builder filter (`%{mode: :builder, column: ..., op: ..., value: ...}`) or a raw
  SQL WHERE expression (`%{mode: :raw, raw_where: ...}`).

  Supports `* All` cross-column search using driver-safe text casting and `ESCAPE '!'`.
  """
  @spec build_filter_select(atom() | String.t(), String.t(), [String.t()], map(), keyword()) ::
          {:ok, statement()} | {:error, term()}
  def build_filter_select(driver, qualified_table, columns, filter_spec, opts \\ []) do
    order_by = Keyword.get(opts, :order_by)
    limit = Keyword.get(opts, :limit, 200)
    sample_row = Keyword.get(opts, :sample_row, [])

    order_sql =
      case order_by do
        {col, dir} when is_binary(col) and dir in [:asc, :desc] ->
          " ORDER BY #{Adapter.quote_identifier(driver, col)} #{if dir == :asc, do: "ASC", else: "DESC"}"

        _ ->
          ""
      end

    limit_sql = if is_integer(limit) and limit > 0, do: " LIMIT #{limit}", else: ""

    case build_filter_where(driver, columns, filter_spec, sample_row) do
      {:ok, "", []} ->
        {:ok, {"SELECT * FROM #{qualified_table}#{order_sql}#{limit_sql};", []}}

      {:ok, where_sql, params} ->
        {:ok, {"SELECT * FROM #{qualified_table} WHERE #{where_sql}#{order_sql}#{limit_sql};", params}}

      {:error, _} = err ->
        err
    end
  end

  defp build_filter_where(_driver, _columns, %{mode: :raw, raw_where: raw}, _sample_row) do
    trimmed = String.trim(to_string(raw || ""))
    {:ok, trimmed, []}
  end

  defp build_filter_where(driver, columns, %{mode: :builder, column: col, op: op, value: val}, sample_row) do
    norm_driver = Adapter.normalize_driver(driver)
    val_str = to_string(val || "")

    cond do
      op == :is_null and col not in ["* All", nil, ""] ->
        {:ok, "#{Adapter.quote_identifier(driver, col)} IS NULL", []}

      op == :is_not_null and col not in ["* All", nil, ""] ->
        {:ok, "#{Adapter.quote_identifier(driver, col)} IS NOT NULL", []}

      col in ["* All", nil, ""] ->
        build_all_columns_where(driver, norm_driver, columns, op, val_str)

      true ->
        build_single_column_where(driver, norm_driver, columns, col, op, val, sample_row)
    end
  end

  defp build_all_columns_where(_driver, _norm_driver, [], _op, _val_str), do: {:error, :no_columns}

  defp build_all_columns_where(driver, norm_driver, columns, op, val_str) do
    if String.trim(val_str) == "" and op not in [:is_null, :is_not_null] do
      {:ok, "", []}
    else
      case op do
        :is_null ->
          clauses = Enum.map(columns, &"#{Adapter.quote_identifier(driver, &1)} IS NULL")
          {:ok, "(" <> Enum.join(clauses, " OR ") <> ")", []}

        :is_not_null ->
          clauses = Enum.map(columns, &"#{Adapter.quote_identifier(driver, &1)} IS NOT NULL")
          {:ok, "(" <> Enum.join(clauses, " OR ") <> ")", []}

        _ ->
          {pattern, like_mode?} =
            case op do
              :starts_with -> {escape_like(val_str) <> "%", true}
              := -> {val_str, false}
              _ -> {"%" <> escape_like(val_str) <> "%", true}
            end

          clauses =
            Enum.map(columns, fn col_name ->
              casted = cast_as_text(norm_driver, Adapter.quote_identifier(driver, col_name))
              ph = placeholder(driver, 1)

              if like_mode? do
                "#{casted} #{like_keyword(norm_driver)} #{ph} ESCAPE '!'"
              else
                "#{casted} = #{ph}"
              end
            end)

          params = if norm_driver == :postgres, do: [pattern], else: List.duplicate(pattern, length(columns))
          {:ok, "(" <> Enum.join(clauses, " OR ") <> ")", params}
      end
    end
  end

  defp build_single_column_where(driver, norm_driver, columns, col, op, val, sample_row) do
    q_col = Adapter.quote_identifier(driver, col)
    ph = placeholder(driver, 1)

    case op do
      :contains ->
        val_str = to_string(val || "")

        if val_str == "" do
          {:ok, "", []}
        else
          casted = cast_as_text(norm_driver, q_col)
          {:ok, "#{casted} #{like_keyword(norm_driver)} #{ph} ESCAPE '!'", ["%" <> escape_like(val_str) <> "%"]}
        end

      :starts_with ->
        val_str = to_string(val || "")

        if val_str == "" do
          {:ok, "", []}
        else
          casted = cast_as_text(norm_driver, q_col)
          {:ok, "#{casted} #{like_keyword(norm_driver)} #{ph} ESCAPE '!'", [escape_like(val_str) <> "%"]}
        end

      op when op in [:=, :!=, :>, :<, :>=, :<=] ->
        if is_nil(val) and op == := do
          {:ok, "#{q_col} IS NULL", []}
        else
          col_idx = Enum.find_index(columns, &(to_string(&1) == col))
          sample_val = if col_idx, do: Enum.at(sample_row, col_idx), else: nil
          coerced = if is_nil(sample_val), do: val, else: coerce_value(val, sample_val)
          sql_op = Atom.to_string(op)
          {:ok, "#{q_col} #{sql_op} #{ph}", [coerced]}
        end

      _ ->
        {:error, :unsupported_operator}
    end
  end

  defp cast_as_text(:mysql, q_col), do: "CAST(#{q_col} AS CHAR)"
  defp cast_as_text(_driver, q_col), do: "CAST(#{q_col} AS TEXT)"

  defp like_keyword(:postgres), do: "ILIKE"
  defp like_keyword(_driver), do: "LIKE"

  defp escape_like(str) do
    str
    |> String.replace("!", "!!")
    |> String.replace("%", "!%")
    |> String.replace("_", "!_")
  end

  defp build_where(driver, columns, orig_row, pk_cols, start_idx) do
    target_pairs =
      if is_list(pk_cols) and pk_cols != [] do
        columns
        |> Enum.zip(orig_row)
        |> Enum.filter(fn {col, _val} -> col in pk_cols end)
      else
        Enum.zip(columns, orig_row)
      end

    if target_pairs == [] do
      {:error, :missing_where_columns}
    else
      {clauses, params, _next_idx} =
        Enum.reduce(target_pairs, {[], [], start_idx}, fn {col, val}, {c_acc, v_acc, idx} ->
          q_col = Adapter.quote_identifier(driver, col)

          if is_nil(val) do
            {c_acc ++ ["#{q_col} IS NULL"], v_acc, idx}
          else
            {c_acc ++ ["#{q_col} = #{placeholder(driver, idx)}"], v_acc ++ [val], idx + 1}
          end
        end)

      {:ok, Enum.join(clauses, " AND "), params}
    end
  end

  defp placeholder(driver, idx) do
    if Adapter.normalize_driver(driver) == :postgres, do: "$#{idx}", else: "?"
  end
end
