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
      tab
      |> :ets.select([{{:_, :"$1"}, [], [:"$1"]}])
      |> Enum.sort_by(&String.downcase(to_string(&1.name || &1.id || "")))
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
  Imports non-wildcard host entries from `path` (default `~/.ssh/config`) into `store`
  without overwriting profiles already saved in the store.
  Returns `{:ok, imported_count}`.
  """
  @spec import_from_ssh_config(atom() | pid(), String.t()) :: {:ok, non_neg_integer()}
  def import_from_ssh_config(store \\ __MODULE__, path \\ "~/.ssh/config") do
    GenServer.call(store, {:import_ssh_config, path})
  end

  @doc """
  Parses SSH config formatted string into a list of SSHProfile structs.
  """
  @spec parse_ssh_config_string(String.t()) :: [SSHProfile.t()]
  def parse_ssh_config_string(content) when is_binary(content) do
    {rev_blocks, current} =
      content
      |> String.split(["\r\n", "\n"])
      |> Enum.map(&strip_comment_and_trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.reduce({[], nil}, fn line, {acc, current} ->
        case parse_line(line) do
          {:host, names} ->
            acc = flush_block(current, acc)

            block = %{
              names: names,
              host: nil,
              port: 22,
              username: nil,
              identity_file: nil
            }

            {acc, block}

          :match ->
            {flush_block(current, acc), nil}

          {:key_val, key, val} ->
            if current do
              {acc, update_current(current, key, val)}
            else
              {acc, current}
            end

          :unknown ->
            {acc, current}
        end
      end)

    rev_blocks
    |> then(&flush_block(current, &1))
    |> Enum.reverse()
    |> Enum.flat_map(&expand_block_to_profiles/1)
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    name = Keyword.get(opts, :name, __MODULE__)
    tab_name = if name == __MODULE__, do: @table_name, else: name
    path = Keyword.get(opts, :config_path) || Strata.Config.ssh_config_path()

    ssh_config_paths =
      Keyword.get_lazy(opts, :ssh_config_paths, fn ->
        if @env == :test, do: [], else: ["~/.ssh/config", "./.ssh/config"]
      end)

    table =
      case :ets.info(tab_name) do
        :undefined ->
          :ets.new(tab_name, [:named_table, :set, :public, read_concurrency: true])

        _ ->
          tab_name
      end

    load_from_disk(table, path)
    Enum.each(ssh_config_paths, &load_from_ssh_config(table, &1))

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
  def handle_call({:import_ssh_config, path}, _from, state) do
    count = load_from_ssh_config(state.table, path)
    {:reply, {:ok, count}, state}
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

  defp load_from_ssh_config(tab, path) when is_binary(path) do
    path
    |> discover_ssh_profiles()
    |> Enum.reduce(0, fn profile, count ->
      if :ets.insert_new(tab, {profile.id, profile}), do: count + 1, else: count
    end)
  end

  defp wildcard_host?(id), do: String.contains?(id, "*") or String.contains?(id, "?")

  defp strip_comment_and_trim(line) do
    trimmed = String.trim(line)

    if String.starts_with?(trimmed, "#") do
      ""
    else
      trimmed
      |> String.split(~r/\s+#/, parts: 2)
      |> hd()
      |> String.trim()
    end
  end

  defp flush_block(nil, acc), do: acc
  defp flush_block(block, acc), do: [block | acc]

  defp expand_block_to_profiles(block) do
    block.names
    |> Enum.reject(&(&1 == "" or wildcard_host?(&1)))
    |> Enum.map(fn host_alias ->
      %SSHProfile{
        id: host_alias,
        name: host_alias,
        host: block.host || host_alias,
        port: block.port,
        username: block.username,
        identity_file: block.identity_file
      }
    end)
  end

  defp parse_line(line) do
    parts = String.split(line, ~r/\s+|=/, parts: 2)

    case parts do
      [key, val] ->
        key_down = String.downcase(key)
        clean_val = String.trim(val)

        cond do
          key_down == "host" ->
            {:host, String.split(clean_val, ~r/\s+/, trim: true)}

          key_down == "match" ->
            :match

          true ->
            {:key_val, key_down, clean_val}
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

    if current.identity_file in [nil, ""],
      do: %{current | identity_file: clean_val},
      else: current
  end

  defp update_current(current, _key, _val), do: current
end
