defmodule Strata.ConfigStore do
  @moduledoc """
  Storage backend that owns and manages connection profiles in ETS (`read_concurrency: true`),
  with debounced atomic persistence to `~/.strata/config.db` and `0o600` file permissions,
  matching `Caudata.ConfigStore`.
  """
  use GenServer
  require Logger

  alias Strata.ConnectionProfile

  @env Application.compile_env(:strata, :env, :prod)
  @allowed_option_keys %{
    "ssl" => :ssl,
    "ssl_opts" => :ssl_opts,
    "timeout" => :timeout,
    "connect_timeout" => :connect_timeout,
    "pool_size" => :pool_size
  }

  # Client API

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec list_profiles(atom() | pid()) :: [ConnectionProfile.t()]
  def list_profiles(store \\ __MODULE__) do
    tab = get_table_name(store)

    try do
      :ets.match_object(tab, {{:profile, :_}, :_})
      |> Enum.map(fn {_, p} -> p end)
    rescue
      _ -> []
    end
  end

  @spec get_profile(atom() | pid(), String.t()) :: ConnectionProfile.t() | nil
  def get_profile(store \\ __MODULE__, id) when is_binary(id) do
    tab = get_table_name(store)

    case :ets.lookup(tab, {:profile, id}) do
      [{_, p}] -> p
      [] -> nil
    end
  rescue
    _ -> nil
  end

  @spec put_profile(atom() | pid(), ConnectionProfile.t()) :: :ok
  def put_profile(store, %ConnectionProfile{} = profile) do
    GenServer.call(store, {:put_profile, profile})
  end

  def put_profile(%ConnectionProfile{} = profile) do
    put_profile(__MODULE__, profile)
  end

  @spec delete_profile(atom() | pid(), String.t()) :: :ok
  def delete_profile(store, id) when is_binary(id) do
    GenServer.call(store, {:delete_profile, id})
  end

  def delete_profile(id) when is_binary(id) do
    delete_profile(__MODULE__, id)
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    name = Keyword.get(opts, :name, __MODULE__)
    path = Keyword.get(opts, :config_path) || Strata.Config.config_path()
    json_path = Keyword.get(opts, :json_path) || Strata.Config.json_config_path()

    tab =
      case :ets.info(name) do
        :undefined ->
          :ets.new(name, [:named_table, :public, :set, read_concurrency: true])

        _ ->
          name
      end

    load_config(tab, path, json_path)

    {:ok, %{table: tab, config_path: path, json_path: json_path, save_timer: nil}}
  end

  @impl true
  def handle_call({:put_profile, %ConnectionProfile{id: id} = profile}, _from, state) do
    :ets.insert(state.table, {{:profile, id}, profile})
    new_state = save_async(state)
    broadcast_profiles_updated(state.table)
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call({:delete_profile, id}, _from, state) do
    :ets.delete(state.table, {:profile, id})
    new_state = save_async(state)
    broadcast_profiles_updated(state.table)
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call(:get_table_name, _from, state) do
    {:reply, state.table, state}
  end

  @impl true
  def handle_info(:perform_save, state) do
    do_perform_save(state)
    {:noreply, %{state | save_timer: nil}}
  end

  @impl true
  def terminate(_reason, state) do
    if state.save_timer do
      Process.cancel_timer(state.save_timer)

      receive do
        :perform_save -> :ok
      after
        0 -> :ok
      end

      do_perform_save(state)
    end

    :ok
  end

  defp get_table_name(store) when is_atom(store), do: store
  defp get_table_name(store) when is_pid(store), do: GenServer.call(store, :get_table_name)

  defp broadcast_profiles_updated(tab) do
    if Process.whereis(Strata.PubSub) do
      profiles =
        :ets.match_object(tab, {{:profile, :_}, :_})
        |> Enum.map(fn {_, p} -> p end)

      Phoenix.PubSub.broadcast(Strata.PubSub, "config:profiles", {:profiles_updated, profiles})
    end
  end

  defp load_config(tab, path, json_path) do
    char_path = String.to_charlist(path)

    if File.exists?(path) do
      case :ets.file2tab(char_path) do
        {:ok, file_tab} ->
          :ets.foldl(
            fn element, _acc ->
              :ets.insert(tab, element)
            end,
            :ok,
            file_tab
          )

          :ets.delete(file_tab)

        {:error, _} ->
          load_json_fallback(tab, json_path)
      end
    else
      load_json_fallback(tab, json_path)
    end
  end

  defp load_json_fallback(tab, json_path) do
    if File.exists?(json_path) do
      case File.read(json_path) do
        {:ok, content} ->
          case Jason.decode(content) do
            {:ok, list} when is_list(list) ->
              Enum.each(list, fn item ->
                p = profile_from_map(item)
                :ets.insert(tab, {{:profile, p.id}, p})
              end)

            _ ->
              :ok
          end

        _ ->
          :ok
      end
    end
  end

  defp save_async(state) do
    if @env == :test do
      do_perform_save(state)
      state
    else
      if state.save_timer, do: Process.cancel_timer(state.save_timer)
      timer = Process.send_after(self(), :perform_save, 200)
      %{state | save_timer: timer}
    end
  end

  defp do_perform_save(state) do
    path = state.config_path
    dir = Path.dirname(path)
    File.mkdir_p!(dir)

    if Path.basename(dir) == ".strata" do
      _ = File.chmod(dir, 0o700)
    end

    file_tab = :ets.new(:strata_config_file, [:set, :public])

    :ets.foldl(
      fn element, _acc ->
        :ets.insert(file_tab, element)
      end,
      :ok,
      state.table
    )

    tmp_path = "#{path}.tmp.#{System.unique_integer([:positive])}"

    try do
      case :ets.tab2file(file_tab, String.to_charlist(tmp_path)) do
        :ok ->
          _ = File.chmod(tmp_path, 0o600)
          File.rename!(tmp_path, path)
          _ = File.chmod(path, 0o600)

        {:error, reason} ->
          Logger.error("Failed to persist config to disk at #{path}: #{inspect(reason)}")
          File.rm(tmp_path)
      end
    rescue
      e ->
        Logger.error("Error persisting config: #{inspect(e)}")
        File.rm(tmp_path)
    after
      :ets.delete(file_tab)
    end

    save_json_fallback(state.table, state.json_path)
  rescue
    _ -> :error
  end

  defp save_json_fallback(tab, json_path) do
    dir = Path.dirname(json_path)
    File.mkdir_p!(dir)

    profiles =
      :ets.match_object(tab, {{:profile, :_}, :_})
      |> Enum.map(fn {_, p} -> p end)

    maps = Enum.map(profiles, &profile_to_map/1)
    tmp_json = "#{json_path}.tmp.#{System.unique_integer([:positive])}"

    case Jason.encode(maps, pretty: true) do
      {:ok, json} ->
        File.write!(tmp_json, json)
        _ = File.chmod(tmp_json, 0o600)
        File.rename!(tmp_json, json_path)
        _ = File.chmod(json_path, 0o600)

      _ ->
        :error
    end
  rescue
    _ -> :error
  end

  def profile_to_map(%ConnectionProfile{} = p) do
    %{
      "id" => p.id,
      "name" => p.name,
      "driver" => to_string(p.driver),
      "host" => p.host,
      "port" => p.port,
      "database" => p.database,
      "username" => p.username,
      "password" => p.password,
      "ssh_profile_id" => p.ssh_profile_id,
      "options" => stringify_keys(p.options || %{})
    }
  end

  def profile_from_map(map) when is_map(map) do
    driver_str = Map.get(map, "driver", "postgres")

    driver =
      case driver_str do
        "mysql" -> :mysql
        "sqlite" -> :sqlite
        _ -> :postgres
      end

    %ConnectionProfile{
      id: Map.get(map, "id") || "conn_" <> Integer.to_string(System.unique_integer([:positive])),
      name: Map.get(map, "name", "Connection"),
      driver: driver,
      host: Map.get(map, "host", "localhost"),
      port: Map.get(map, "port") || default_port(driver),
      database: Map.get(map, "database", ""),
      username: Map.get(map, "username", ""),
      password: Map.get(map, "password", ""),
      ssh_profile_id: Map.get(map, "ssh_profile_id"),
      options: symbolize_keys(Map.get(map, "options", %{}))
    }
  end

  defp default_port(:postgres), do: 5432
  defp default_port(:mysql), do: 3306
  defp default_port(_), do: 0

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), v} end)
  end

  defp symbolize_keys(map) when is_map(map) do
    Enum.reduce(map, %{}, fn {k, v}, acc ->
      key_str = to_string(k)

      case Map.fetch(@allowed_option_keys, key_str) do
        {:ok, atom_key} -> Map.put(acc, atom_key, v)
        :error -> acc
      end
    end)
  end
end
