defmodule Strata.AISettingsStore do
  @moduledoc """
  GenServer owning persisted `Strata.AISettings` in ETS (`read_concurrency: true`)
  with atomic JSON persistence to `~/.strata/ai_settings.json` (`0o600`).
  """
  use GenServer
  require Logger

  alias Strata.AISettings

  @env Application.compile_env(:strata, :env, :prod)

  # Client API

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Returns the current persisted `Strata.AISettings`.
  Falls back to `Strata.AISettings.default/0` if the store is not started.
  """
  @spec get(atom() | pid()) :: AISettings.t()
  def get(store \\ __MODULE__) do
    tab = get_table_name(store)

    case :ets.lookup(tab, :settings) do
      [{:settings, %AISettings{} = settings}] -> settings
      _ -> AISettings.default()
    end
  rescue
    _ -> AISettings.default()
  catch
    :exit, _ -> AISettings.default()
  end

  @doc """
  Saves `Strata.AISettings` in ETS and persists to disk.
  """
  @spec put(atom() | pid(), AISettings.t()) :: :ok
  def put(store \\ __MODULE__, %AISettings{} = settings) do
    GenServer.call(store, {:put, settings})
  end

  @doc """
  Resets `Strata.AISettings` back to defaults.
  """
  @spec reset(atom() | pid()) :: :ok
  def reset(store \\ __MODULE__) do
    put(store, AISettings.default())
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    name = Keyword.get(opts, :name, __MODULE__)
    path = Keyword.get(opts, :settings_path) || Strata.Config.ai_settings_path()

    tab =
      case :ets.info(name) do
        :undefined ->
          :ets.new(name, [:named_table, :public, :set, read_concurrency: true])

        _ ->
          name
      end

    settings = load_settings(path)
    :ets.insert(tab, {:settings, settings})

    {:ok, %{table: tab, settings_path: path, save_timer: nil}}
  end

  @impl true
  def handle_call({:put, %AISettings{} = settings}, _from, state) do
    :ets.insert(state.table, {:settings, settings})
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

  defp get_table_name(store) when is_atom(store), do: store
  defp get_table_name(store) when is_pid(store), do: GenServer.call(store, :get_table_name)

  defp load_settings(path) do
    if File.exists?(path) do
      with {:ok, content} <- File.read(path),
           {:ok, map} when is_map(map) <- Jason.decode(content) do
        AISettings.from_map(map)
      else
        _ -> AISettings.default()
      end
    else
      AISettings.default()
    end
  end

  defp save_async(state) do
    if @env == :test do
      do_perform_save(state)
      state
    else
      if state.save_timer, do: Process.cancel_timer(state.save_timer)
      timer = Process.send_after(self(), :perform_save, 150)
      %{state | save_timer: timer}
    end
  end

  defp do_perform_save(state) do
    path = state.settings_path
    dir = Path.dirname(path)
    File.mkdir_p!(dir)

    if Path.basename(dir) == ".strata" do
      _ = File.chmod(dir, 0o700)
    end

    settings =
      case :ets.lookup(state.table, :settings) do
        [{:settings, %AISettings{} = s}] -> s
        _ -> AISettings.default()
      end

    tmp_path = "#{path}.tmp.#{System.unique_integer([:positive])}"

    case Jason.encode(AISettings.to_map(settings), pretty: true) do
      {:ok, json} ->
        File.write!(tmp_path, json)
        _ = File.chmod(tmp_path, 0o600)
        File.rename!(tmp_path, path)
        _ = File.chmod(path, 0o600)

      {:error, reason} ->
        Logger.error("Failed to encode AI settings: #{inspect(reason)}")
    end
  rescue
    e ->
      Logger.error("Error persisting AI settings: #{inspect(e)}")
      :error
  end
end
