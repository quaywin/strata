defmodule Strata.DataStore do
  @moduledoc """
  ETS-backed storage for tabular query results, table data caching, and pagination support.
  Provides zero-latency direct ETS reads for the TUI render loop.
  """
  use GenServer

  @table_name :strata_data_store

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Stores a query result set for a tab_id.
  `columns` is a list of column names.
  `rows` is a list of row tuples or lists.
  `total_rows` is optional and represents total records in DB (or length of rows if not provided).
  """
  @spec put_result_set(String.t(), [String.t()], [list()], integer() | nil) :: :ok
  def put_result_set(tab_id, columns, rows, total_rows \\ nil) when is_binary(tab_id) do
    loaded = length(rows)
    total = total_rows || loaded
    true = :ets.insert(@table_name, {tab_id, columns, rows, loaded, total})
    :ok
  end

  @doc """
  Retrieves a paginated slice of rows for a tab_id.
  Returns `{columns, sliced_rows, loaded_rows_count, total_rows}`.
  Page is 1-indexed.
  """
  @spec get_page(String.t(), integer(), integer()) ::
          {[String.t()], [list()], integer(), integer()}
  def get_page(tab_id, page, page_size) when is_binary(tab_id) and page >= 1 and page_size >= 1 do
    case :ets.lookup(@table_name, tab_id) do
      [{^tab_id, columns, rows, loaded_count, total_rows}] ->
        offset = (page - 1) * page_size
        sliced_rows = Enum.slice(rows, offset, page_size)
        {columns, sliced_rows, loaded_count, total_rows}

      [] ->
        {[], [], 0, 0}
    end
  end

  @doc """
  Retrieves all rows stored for a tab_id.
  Returns `{columns, rows}` or `nil`.
  """
  @spec get_rows(String.t()) :: {[String.t()], [list()]} | nil
  def get_rows(tab_id) when is_binary(tab_id) do
    case :ets.lookup(@table_name, tab_id) do
      [{^tab_id, columns, rows, _loaded, _total}] -> {columns, rows}
      [] -> nil
    end
  end

  @doc """
  Deletes result set for a specific tab_id.
  """
  @spec delete_result_set(String.t()) :: :ok
  def delete_result_set(tab_id) when is_binary(tab_id) do
    true = :ets.delete(@table_name, tab_id)
    :ok
  end

  # --- Connection-scoped Table Data Cache (ISSUE-001) ---

  @doc """
  Caches table rows in ETS scoped by `{conn_id, schema, table_name}`.
  """
  @spec put_table_cache(
          String.t(),
          String.t() | nil,
          String.t(),
          [String.t()],
          [list()],
          boolean()
        ) :: :ok
  def put_table_cache(conn_id, schema, table_name, columns, rows, has_more \\ false)
      when is_binary(conn_id) and is_binary(table_name) do
    if :ets.info(@table_name) != :undefined do
      key = table_cache_key(conn_id, schema, table_name)

      entry = %{
        columns: columns,
        rows: rows,
        total_rows: length(rows),
        has_more: has_more,
        fetched_at: DateTime.utc_now()
      }

      true = :ets.insert(@table_name, {key, entry})
    end

    :ok
  end

  @doc """
  Reads cached table data directly from ETS without blocking.
  Returns `{:ok, entry}` or `:miss`.
  """
  @spec get_table_cache(String.t(), String.t() | nil, String.t()) :: {:ok, map()} | :miss
  def get_table_cache(conn_id, schema, table_name)
      when is_binary(conn_id) and is_binary(table_name) do
    if :ets.info(@table_name) != :undefined do
      key = table_cache_key(conn_id, schema, table_name)

      case :ets.lookup(@table_name, key) do
        [{^key, entry}] -> {:ok, entry}
        [] -> :miss
      end
    else
      :miss
    end
  end

  @doc """
  Appends deduplicated rows to an existing cached table entry.
  """
  @spec append_table_cache(String.t(), String.t() | nil, String.t(), [list()], boolean()) :: :ok
  def append_table_cache(conn_id, schema, table_name, new_rows, has_more)
      when is_binary(conn_id) and is_binary(table_name) and is_list(new_rows) do
    case get_table_cache(conn_id, schema, table_name) do
      {:ok, entry} ->
        existing_set = MapSet.new(entry.rows)
        unique_new = Enum.reject(new_rows, &MapSet.member?(existing_set, &1))
        updated_rows = entry.rows ++ unique_new
        put_table_cache(conn_id, schema, table_name, entry.columns, updated_rows, has_more)

      :miss ->
        :ok
    end
  end

  @doc """
  Stores cached schema inspection metadata for a table.
  """
  @spec put_schema_cache(String.t(), String.t() | nil, String.t(), map()) :: :ok
  def put_schema_cache(conn_id, schema, table_name, schema_info)
      when is_binary(conn_id) and is_binary(table_name) and is_map(schema_info) do
    if :ets.info(@table_name) != :undefined do
      key = schema_cache_key(conn_id, schema, table_name)
      true = :ets.insert(@table_name, {key, schema_info})
    end

    :ok
  end

  @doc """
  Retrieves cached schema inspection metadata for a table.
  """
  @spec get_schema_cache(String.t(), String.t() | nil, String.t()) :: {:ok, map()} | :miss
  def get_schema_cache(conn_id, schema, table_name)
      when is_binary(conn_id) and is_binary(table_name) do
    if :ets.info(@table_name) != :undefined do
      case :ets.lookup(@table_name, schema_cache_key(conn_id, schema, table_name)) do
        [{_key, schema_info}] -> {:ok, schema_info}
        [] -> :miss
      end
    else
      :miss
    end
  end

  @doc """
  Stores lightweight prefetched column names for `table_name` without overwriting
  full Structure Inspector metadata in `:schema_cache`.
  """
  @spec put_columns_cache(String.t(), String.t() | nil, String.t(), [String.t()]) :: :ok
  def put_columns_cache(conn_id, schema, table_name, columns)
      when is_binary(conn_id) and is_binary(table_name) and is_list(columns) do
    if :ets.info(@table_name) != :undefined do
      key = {:columns_cache, conn_id, schema || "default", table_name}
      true = :ets.insert(@table_name, {key, columns})
    end

    :ok
  end

  @doc """
  Returns a map of `%{table_name => [column_name]}` from cached table schemas and
  prefetched column caches for `conn_id`.
  When `conn_id` is `nil`, returns cached columns across all connections.
  """
  @spec cached_columns(String.t() | nil) :: %{String.t() => [String.t()]}
  def cached_columns(conn_id \\ nil) do
    if :ets.info(@table_name) != :undefined do
      schema_pattern =
        if is_binary(conn_id),
          do: {{:schema_cache, conn_id, :_, :_}, :_},
          else: {{:schema_cache, :_, :_, :_}, :_}

      col_pattern =
        if is_binary(conn_id),
          do: {{:columns_cache, conn_id, :_, :_}, :_},
          else: {{:columns_cache, :_, :_, :_}, :_}

      from_schema =
        :ets.match_object(@table_name, schema_pattern)
        |> Enum.reduce(%{}, fn {{:schema_cache, _cid, _schema, table_name}, schema_info}, acc ->
          cols =
            schema_info
            |> Map.get(:rows, [])
            |> Enum.map(fn
              [col | _] when is_binary(col) -> col
              _ -> nil
            end)
            |> Enum.reject(&(&1 in [nil, ""]))

          if cols != [] do
            Map.update(acc, table_name, cols, &Enum.uniq(&1 ++ cols))
          else
            acc
          end
        end)

      :ets.match_object(@table_name, col_pattern)
      |> Enum.reduce(from_schema, fn {{:columns_cache, _cid, _schema, table_name}, cols}, acc ->
        clean_cols = Enum.filter(cols, &(is_binary(&1) and &1 != ""))

        if clean_cols != [] do
          Map.update(acc, table_name, clean_cols, &Enum.uniq(&1 ++ clean_cols))
        else
          acc
        end
      end)
    else
      %{}
    end
  end

  @doc """
  Invalidates cached data for a single table.
  """
  @spec invalidate_table_cache(String.t(), String.t() | nil, String.t()) :: :ok
  def invalidate_table_cache(conn_id, schema, table_name)
      when is_binary(conn_id) and is_binary(table_name) do
    if :ets.info(@table_name) != :undefined do
      true = :ets.delete(@table_name, table_cache_key(conn_id, schema, table_name))
      true = :ets.delete(@table_name, schema_cache_key(conn_id, schema, table_name))
    end

    :ok
  end

  @doc """
  Invalidates all cached tables belonging to a connection ID.
  """
  @spec invalidate_connection_cache(String.t()) :: :ok
  def invalidate_connection_cache(conn_id) when is_binary(conn_id) do
    if :ets.info(@table_name) != :undefined do
      :ets.match_delete(@table_name, {{:table_cache, conn_id, :_, :_}, :_})
      :ets.match_delete(@table_name, {{:schema_cache, conn_id, :_, :_}, :_})
    end

    :ok
  end

  defp table_cache_key(conn_id, schema, table_name) do
    {:table_cache, conn_id, schema || "default", table_name}
  end

  defp schema_cache_key(conn_id, schema, table_name) do
    {:schema_cache, conn_id, schema || "default", table_name}
  end

  @doc """
  Clears all result sets from DataStore.
  """
  @spec clear() :: :ok
  def clear do
    true = :ets.delete_all_objects(@table_name)
    :ok
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    table =
      case :ets.info(@table_name) do
        :undefined ->
          :ets.new(@table_name, [:named_table, :set, :public, read_concurrency: true])

        _ ->
          @table_name
      end

    {:ok, %{table: table}}
  end
end
