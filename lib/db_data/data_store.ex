defmodule DBData.DataStore do
  @moduledoc """
  ETS-backed storage for tabular query results and pagination support.
  Provides zero-latency direct ETS reads for the TUI render loop.
  """
  use GenServer

  @table_name :db_data_data_store

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
    total = total_rows || length(rows)
    true = :ets.insert(@table_name, {tab_id, columns, rows, total})
    :ok
  end

  @doc """
  Alias for `put_result_set/4`.
  """
  @spec store_result(String.t(), [String.t()], [list()], integer() | nil) :: :ok
  def store_result(tab_id, columns, rows, total_rows \\ nil) do
    put_result_set(tab_id, columns, rows, total_rows)
  end

  @doc """
  Retrieves a paginated slice of rows for a tab_id.
  Returns `{columns, sliced_rows, loaded_rows_count, total_rows}`.
  Page is 1-indexed.
  """
  @spec get_page(String.t(), integer(), integer()) :: {[String.t()], [list()], integer(), integer()}
  def get_page(tab_id, page, page_size) when is_binary(tab_id) and page >= 1 and page_size >= 1 do
    case :ets.lookup(@table_name, tab_id) do
      [{^tab_id, columns, rows, total_rows}] ->
        offset = (page - 1) * page_size
        sliced_rows = Enum.slice(rows, offset, page_size)
        loaded_count = length(rows)
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
      [{^tab_id, columns, rows, _total_rows}] -> {columns, rows}
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
    table = :ets.new(@table_name, [:named_table, :set, :public, read_concurrency: true])
    {:ok, %{table: table}}
  end
end
