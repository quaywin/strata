defmodule DBData.LogStore do
  @moduledoc """
  ETS-backed circular buffer storage for SQL execution logs and stats.
  Maintains a fixed capacity of recent log entries with fast ETS querying.
  """
  use GenServer

  @table_name :db_data_log_store
  @default_max_capacity 1000

  # Client API

  def start_link(opts \\ []) do
    max_capacity = Keyword.get(opts, :max_capacity, @default_max_capacity)
    GenServer.start_link(__MODULE__, [max_capacity: max_capacity], name: __MODULE__)
  end

  @doc """
  Adds a log entry for a specific tab_id or from a log map.
  `log_map` can contain `:status`, `:query`, `:duration_ms`, `:rows`, etc.
  """
  @spec add_log(String.t() | nil, map()) :: :ok
  def add_log(tab_id, log_map) when is_map(log_map) do
    GenServer.call(__MODULE__, {:add_log, tab_id, log_map})
  end

  @doc """
  Adds a log entry where tab_id is optional or included in the log map.
  """
  @spec add_log(map()) :: :ok
  def add_log(log_map) when is_map(log_map) do
    tab_id = Map.get(log_map, :tab_id) || Map.get(log_map, "tab_id")
    add_log(tab_id, log_map)
  end

  @doc """
  Retrieves logs filtered by tab_id. If tab_id is `nil` or `:all`, returns all logs.
  """
  @spec get_logs(String.t() | nil | :all, keyword()) :: [map()]
  def get_logs(tab_id \\ nil, _opts \\ []) do
    case tab_id do
      nil ->
        match_spec = [{{:"$1", :_, :"$2"}, [], [:"$2"]}]
        :ets.select(@table_name, match_spec)

      :all ->
        match_spec = [{{:"$1", :_, :"$2"}, [], [:"$2"]}]
        :ets.select(@table_name, match_spec)

      id when is_binary(id) ->
        match_spec = [{{:"$1", id, :"$2"}, [], [:"$2"]}]
        :ets.select(@table_name, match_spec)
    end
  end

  @doc """
  Clears all log entries from LogStore.
  """
  @spec clear_logs() :: :ok
  def clear_logs do
    GenServer.call(__MODULE__, :clear_logs)
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    max_capacity = Keyword.get(opts, :max_capacity, @default_max_capacity)
    table = :ets.new(@table_name, [:named_table, :ordered_set, :public, read_concurrency: true])
    {:ok, %{table: table, seq: 0, max_capacity: max_capacity}}
  end

  @impl true
  def handle_call({:add_log, tab_id, log_map}, _from, state) do
    seq = state.seq + 1
    timestamp = Map.get(log_map, :timestamp) || DateTime.utc_now()
    entry = Map.merge(%{id: seq, tab_id: tab_id, timestamp: timestamp}, log_map)

    true = :ets.insert(@table_name, {seq, tab_id, entry})

    if seq > state.max_capacity do
      prune_before = seq - state.max_capacity + 1
      :ets.select_delete(@table_name, [{{:"$1", :_, :_}, [{:<, :"$1", prune_before}], [true]}])
    end

    {:reply, :ok, %{state | seq: seq}}
  end

  @impl true
  def handle_call(:clear_logs, _from, state) do
    true = :ets.delete_all_objects(@table_name)
    {:reply, :ok, %{state | seq: 0}}
  end
end
