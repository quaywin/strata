defmodule Strata.SSHProfileStore do
  @moduledoc """
  ETS-backed store for SSH tunnel profiles with debounced atomic persistence to `~/.strata/ssh_profiles.db`.
  Also parses `~/.ssh/config` for auto-discovery.
  """
  use GenServer
  require Logger

  alias Strata.SSHProfile

  @env Application.compile_env(:strata, :env, :prod)
  @table_name :strata_ssh_profile_store

  # Client API

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec put_profile(atom() | pid(), SSHProfile.t()) :: :ok
  def put_profile(store \\ __MODULE__, %SSHProfile{id: id} = profile) when is_binary(id) do
    GenServer.call(store, {:put_profile, profile})
  end

  @spec get_profile(atom() | pid(), String.t()) :: SSHProfile.t() | nil
  def get_profile(store \\ __MODULE__, id) when is_binary(id) do
    tab = get_table_name(store)

    try do
      case :ets.lookup(tab, id) do
        [{^id, profile}] -> profile
        [] -> nil
      end
    rescue
      _ -> nil
    catch
      _, _ -> nil
    end
  end

  @spec list_profiles(atom() | pid()) :: [SSHProfile.t()]
  def list_profiles(store \\ __MODULE__) do
    tab = get_table_name(store)

    try do
      :ets.select(tab, [{{:_, :"$1"}, [], [:"$1"]}])
    rescue
      _ -> []
    catch
      _, _ -> []
    end
  end

  @spec delete_profile(atom() | pid(), String.t()) :: :ok
  def delete_profile(store \\ __MODULE__, id) when is_binary(id) do
    GenServer.call(store, {:delete_profile, id})
  end

  @doc """
  Reads and parses an SSH config file (default `~/.ssh/config`) into `SSHProfile` structs.
  """
  @spec discover_ssh_profiles(String.t()) :: [SSHProfile.t()]
  def discover_ssh_profiles(path \\ "~/.ssh/config") do
    expanded = Path.expand(path)

    case File.read(expanded) do
      {:ok, content} -> parse_ssh_config_string(content)
      _ -> []
    end
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
          acc =
            if current && not wildcard_host?(current.id) && current.host,
              do: [finish_profile(current) | acc],
              else: acc

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
      if current && not wildcard_host?(current.id) && current.host do
        [finish_profile(current) | acc]
      else
        acc
      end
    end)
    |> Enum.reverse()
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    name = Keyword.get(opts, :name, __MODULE__)
    tab_name = if name == __MODULE__, do: @table_name, else: name
    path = Keyword.get(opts, :config_path) || Strata.Config.ssh_config_path()

    table =
      case :ets.info(tab_name) do
        :undefined ->
          :ets.new(tab_name, [:named_table, :set, :public, read_concurrency: true])

        _ ->
          tab_name
      end

    load_from_disk(table, path)

    {:ok, %{table: table, config_path: path, save_timer: nil}}
  end

  @impl true
  def handle_call({:put_profile, %SSHProfile{id: id} = profile}, _from, state) do
    true = :ets.insert(state.table, {id, profile})
    new_state = save_async(state)
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call({:delete_profile, id}, _from, state) do
    true = :ets.delete(state.table, id)
    new_state = save_async(state)
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

  # Helpers

  defp get_table_name(__MODULE__), do: @table_name
  defp get_table_name(store) when is_atom(store), do: store
  defp get_table_name(store) when is_pid(store), do: GenServer.call(store, :get_table_name)

  defp load_from_disk(tab, path) do
    if File.exists?(path) do
      case :ets.file2tab(String.to_charlist(path)) do
        {:ok, file_tab} ->
          :ets.foldl(
            fn element, _acc -> :ets.insert(tab, element) end,
            :ok,
            file_tab
          )

          :ets.delete(file_tab)

        {:error, _} ->
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

    file_tab = :ets.new(:strata_ssh_file, [:set, :public])

    :ets.foldl(
      fn element, _acc -> :ets.insert(file_tab, element) end,
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
          Logger.error("Failed to persist SSH profiles to #{path}: #{inspect(reason)}")
          File.rm(tmp_path)
      end
    rescue
      e ->
        Logger.error("Error persisting SSH profiles: #{inspect(e)}")
        File.rm(tmp_path)
    after
      :ets.delete(file_tab)
    end
  rescue
    _ -> :error
  end

  defp wildcard_host?(id), do: String.contains?(id, "*") or String.contains?(id, "?")

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

  defp update_current(current, "identityfile", val) do
    clean_val = String.replace(val, ~r/^"|"$/, "")
    %{current | identity_file: clean_val}
  end

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
