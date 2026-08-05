defmodule DBData.SSHProfileStore do
  use GenServer

  alias DBData.SSHProfile

  @table_name :db_data_ssh_profile_store

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec put_profile(SSHProfile.t()) :: :ok
  def put_profile(%SSHProfile{id: id} = profile) when is_binary(id) do
    GenServer.call(__MODULE__, {:put_profile, profile})
  end

  @spec get_profile(String.t()) :: SSHProfile.t() | nil
  def get_profile(id) when is_binary(id) do
    case :ets.lookup(@table_name, id) do
      [{^id, profile}] -> profile
      [] -> nil
    end
  end

  @spec list_profiles() :: [SSHProfile.t()]
  def list_profiles do
    :ets.select(@table_name, [{{:_, :"$1"}, [], [:"$1"]}])
  end

  @spec delete_profile(String.t()) :: :ok
  def delete_profile(id) when is_binary(id) do
    GenServer.call(__MODULE__, {:delete_profile, id})
  end

  @doc """
  Parses SSH config formatted string into a list of SSHProfile structs.
  """
  @spec parse_ssh_config_string(String.t()) :: [SSHProfile.t()]
  def parse_ssh_config_string(content) when is_binary(content) do
    content
    |> String.split(["\r\n", "\n"])
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(String.starts_with?(&1, "#") or &1 == ""))
    |> Enum.reduce({[], nil}, fn line, {acc, current} ->
      case parse_line(line) do
        {:host, name} ->
          acc = if current && current.id != "*" && current.host, do: [finish_profile(current) | acc], else: acc
          {acc, %{id: name, name: name, host: nil, port: 22, username: nil, identity_file: nil}}

        {:key_val, key, val} ->
          if current do
            updated = update_current(current, key, val)
            {acc, updated}
          else
            {acc, current}
          end

        :unknown ->
          {acc, current}
      end
    end)
    |> then(fn {acc, current} ->
      if current && current.id != "*" && current.host do
        [finish_profile(current) | acc]
      else
        acc
      end
    end)
    |> Enum.reverse()
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    table = :ets.new(@table_name, [:named_table, :set, :public, read_concurrency: true])
    {:ok, %{table: table}}
  end

  @impl true
  def handle_call({:put_profile, %SSHProfile{id: id} = profile}, _from, state) do
    true = :ets.insert(@table_name, {id, profile})
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:delete_profile, id}, _from, state) do
    true = :ets.delete(@table_name, id)
    {:reply, :ok, state}
  end

  # Helpers

  defp parse_line(line) do
    parts = String.split(line, ~r/\s+|=/, parts: 2)

    case parts do
      [key, val] ->
        key_down = String.downcase(key)

        if key_down == "host" do
          {:host, String.trim(val)}
        else
          {:key_val, key_down, String.trim(val)}
        end

      _ ->
        :unknown
    end
  end

  defp update_current(current, "hostname", val), do: %{current | host: val}
  defp update_current(current, "user", val), do: %{current | username: val}
  defp update_current(current, "port", val) do
    case Integer.parse(val) do
      {port, _} -> %{current | port: port}
      :error -> current
    end
  end
  defp update_current(current, "identityfile", val), do: %{current | identity_file: val}
  defp update_current(current, _key, _val), do: current

  defp finish_profile(map) do
    %SSHProfile{
      id: map.id,
      name: map.name,
      host: map.host,
      port: map.port,
      username: map.username,
      identity_file: map.identity_file
    }
  end
end
