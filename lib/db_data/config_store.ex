defmodule DBData.ConfigStore do
  use GenServer

  alias DBData.ConnectionProfile

  @table_name :db_data_config_store

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec put_profile(ConnectionProfile.t()) :: :ok
  def put_profile(%ConnectionProfile{id: id} = profile) when is_binary(id) do
    GenServer.call(__MODULE__, {:put_profile, profile})
  end

  @spec get_profile(String.t()) :: ConnectionProfile.t() | nil
  def get_profile(id) when is_binary(id) do
    case :ets.lookup(@table_name, id) do
      [{^id, profile}] -> profile
      [] -> nil
    end
  end

  @spec list_profiles() :: [ConnectionProfile.t()]
  def list_profiles do
    :ets.select(@table_name, [{{:_ , :"$1"}, [], [:"$1"]}])
  end

  @spec delete_profile(String.t()) :: :ok
  def delete_profile(id) when is_binary(id) do
    GenServer.call(__MODULE__, {:delete_profile, id})
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    table = :ets.new(@table_name, [:named_table, :set, :public, read_concurrency: true])
    {:ok, %{table: table}}
  end

  @impl true
  def handle_call({:put_profile, %ConnectionProfile{id: id} = profile}, _from, state) do
    true = :ets.insert(@table_name, {id, profile})
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:delete_profile, id}, _from, state) do
    true = :ets.delete(@table_name, id)
    {:reply, :ok, state}
  end
end
