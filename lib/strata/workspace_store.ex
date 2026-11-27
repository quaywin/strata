defmodule Strata.WorkspaceStore do
  @moduledoc """
  GenServer owning persisted SQL query tabs, per-tab AI chat histories, and recently
  closed non-empty SQL tabs (`closed_tabs`) in ETS with debounced atomic JSON
  persistence to `~/.strata/workspace.json` (`0o600`).
  """
  use GenServer
  require Logger

  @env Application.compile_env(:strata, :env, :prod)
  @max_closed_tabs 30

  @type saved_workspace :: %{
          active_tab_id: String.t() | nil,
          tabs: [map()],
          closed_tabs: [map()],
          ai_panel_open: boolean()
        }

  # Client API

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Loads the persisted SQL query tabs, active tab ID, closed tabs, and AI panel state from ETS.
  Returns `%{active_tab_id: ..., tabs: [...], closed_tabs: [...], ai_panel_open: boolean()}`.
  """
  @spec load(atom() | pid()) :: saved_workspace()
  def load(store \\ __MODULE__) do
    tab = get_table_name(store)

    case :ets.lookup(tab, :workspace) do
      [{:workspace, %{} = ws}] ->
        ws
        |> Map.put_new(:closed_tabs, [])
        |> Map.put_new(:ai_panel_open, false)

      _ ->
        %{active_tab_id: nil, tabs: [], closed_tabs: [], ai_panel_open: false}
    end
  rescue
    _ -> %{active_tab_id: nil, tabs: [], closed_tabs: [], ai_panel_open: false}
  catch
    :exit, _ -> %{active_tab_id: nil, tabs: [], closed_tabs: [], ai_panel_open: false}
  end

  @doc """
  Schedules debounced persistence of `:query` tabs, `active_tab_id`, and optionally `closed_tabs` / `opts`.
  When `closed_tabs` is `nil`, preserves the existing `closed_tabs` list in ETS.
  """
  @spec save([map()], String.t() | nil) :: :ok
  def save(tabs, active_tab_id) when is_list(tabs) do
    save(__MODULE__, tabs, active_tab_id, nil, [])
  end

  @spec save(atom() | pid(), [map()], String.t() | nil) :: :ok
  def save(store, tabs, active_tab_id)
      when (is_atom(store) or is_pid(store)) and is_list(tabs) do
    save(store, tabs, active_tab_id, nil, [])
  end

  @spec save([map()], String.t() | nil, [map()] | nil) :: :ok
  def save(tabs, active_tab_id, closed_tabs) when is_list(tabs) do
    save(__MODULE__, tabs, active_tab_id, closed_tabs, [])
  end

  @spec save([map()], String.t() | nil, [map()] | nil, keyword()) :: :ok
  def save(tabs, active_tab_id, closed_tabs, opts) when is_list(tabs) and is_list(opts) do
    save(__MODULE__, tabs, active_tab_id, closed_tabs, opts)
  end

  @spec save(atom() | pid(), [map()], String.t() | nil, [map()] | nil, keyword()) :: :ok
  def save(store, tabs, active_tab_id, closed_tabs, opts \\ [])
      when (is_atom(store) or is_pid(store)) and is_list(tabs) and is_list(opts) do
    existing = load(store)
    existing_closed = if is_nil(closed_tabs), do: existing.closed_tabs, else: closed_tabs
    ai_open = Keyword.get(opts, :ai_panel_open, existing.ai_panel_open)
    payload = serialize_workspace(tabs, active_tab_id, existing_closed, ai_open)
    GenServer.cast(store, {:save, payload})
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  @doc """
  Synchronously saves `:query` tabs, `active_tab_id`, and optionally `closed_tabs` / `opts` to disk.
  """
  @spec save_sync([map()], String.t() | nil) :: :ok
  def save_sync(tabs, active_tab_id) when is_list(tabs) do
    save_sync(__MODULE__, tabs, active_tab_id, nil, [])
  end

  @spec save_sync(atom() | pid(), [map()], String.t() | nil) :: :ok
  def save_sync(store, tabs, active_tab_id)
      when (is_atom(store) or is_pid(store)) and is_list(tabs) do
    save_sync(store, tabs, active_tab_id, nil, [])
  end

  @spec save_sync([map()], String.t() | nil, [map()] | nil) :: :ok
  def save_sync(tabs, active_tab_id, closed_tabs) when is_list(tabs) do
    save_sync(__MODULE__, tabs, active_tab_id, closed_tabs, [])
  end

  @spec save_sync([map()], String.t() | nil, [map()] | nil, keyword()) :: :ok
  def save_sync(tabs, active_tab_id, closed_tabs, opts)
      when is_list(tabs) and is_list(opts) do
    save_sync(__MODULE__, tabs, active_tab_id, closed_tabs, opts)
  end

  @spec save_sync(atom() | pid(), [map()], String.t() | nil, [map()] | nil, keyword()) :: :ok
  def save_sync(store, tabs, active_tab_id, closed_tabs, opts \\ [])
      when (is_atom(store) or is_pid(store)) and is_list(tabs) and is_list(opts) do
    existing = load(store)
    existing_closed = if is_nil(closed_tabs), do: existing.closed_tabs, else: closed_tabs
    ai_open = Keyword.get(opts, :ai_panel_open, existing.ai_panel_open)
    payload = serialize_workspace(tabs, active_tab_id, existing_closed, ai_open)
    GenServer.call(store, {:save_sync, payload})
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  @doc """
  Builds a normalized closed-tab archive entry from a `:query` tab if it contains SQL or AI chat history.
  Returns `nil` for blank tabs.
  """
  @spec build_closed_tab_entry(map(), String.t() | nil) :: map() | nil
  def build_closed_tab_entry(tab, closed_at \\ nil) when is_map(tab) do
    content = to_string(Map.get(tab, :content) || "")

    ai_messages =
      tab
      |> Map.get(:ai_messages, [])
      |> Enum.reject(&(Map.get(&1, :status) == :running))

    if Map.get(tab, :kind, :query) == :query and
         (String.trim(content) != "" or ai_messages != []) do
      base = serialize_tab(%{tab | ai_messages: ai_messages})
      ts = closed_at || current_local_iso()

      Map.merge(base, %{
        id: "closed_" <> Integer.to_string(System.unique_integer([:positive])),
        closed_at: ts
      })
    else
      nil
    end
  end

  @doc """
  Prepends a closed-tab entry to `closed_tabs`, deduplicating identical head/entries and capping at #{@max_closed_tabs}.
  """
  @spec prepend_closed_tab([map()], map() | nil) :: [map()]
  def prepend_closed_tab(closed_tabs, nil) when is_list(closed_tabs), do: closed_tabs

  def prepend_closed_tab(closed_tabs, entry) when is_list(closed_tabs) and is_map(entry) do
    filtered =
      Enum.reject(closed_tabs, fn existing ->
        Map.get(existing, :profile_id) == Map.get(entry, :profile_id) and
          Map.get(existing, :content) == entry.content and
          Map.get(existing, :ai_messages, []) == entry.ai_messages and
          Map.get(existing, :name) == entry.name
      end)

    [entry | filtered] |> Enum.take(@max_closed_tabs)
  end

  @doc """
  Returns current local timestamp truncated to seconds in ISO-8601 format.
  """
  @spec current_local_iso() :: String.t()
  def current_local_iso do
    NaiveDateTime.local_now()
    |> NaiveDateTime.truncate(:second)
    |> NaiveDateTime.to_iso8601()
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    name = Keyword.get(opts, :name, __MODULE__)
    path = Keyword.get(opts, :workspace_path) || Strata.Config.workspace_path()

    tab =
      case :ets.info(name) do
        :undefined ->
          :ets.new(name, [:named_table, :public, :set, read_concurrency: true])

        _ ->
          name
      end

    workspace =
      if @env == :test and is_nil(Keyword.get(opts, :workspace_path)) do
        %{active_tab_id: nil, tabs: [], closed_tabs: [], ai_panel_open: false}
      else
        load_from_disk(path)
      end

    :ets.insert(tab, {:workspace, workspace})
    {:ok, %{table: tab, workspace_path: path, save_timer: nil}}
  end

  @impl true
  def handle_cast({:save, payload}, state) do
    :ets.insert(state.table, {:workspace, payload})
    {:noreply, schedule_save(state)}
  end

  @impl true
  def handle_call({:save_sync, payload}, _from, state) do
    if state.save_timer, do: Process.cancel_timer(state.save_timer)
    :ets.insert(state.table, {:workspace, payload})
    do_perform_save(%{state | save_timer: nil})
    {:reply, :ok, %{state | save_timer: nil}}
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

  @doc """
  Extracts and normalizes `:query` tabs, AI chat history, `closed_tabs`, and `ai_panel_open` for persistence.
  """
  @spec serialize_workspace([map()], String.t() | nil, [map()], boolean()) :: saved_workspace()
  def serialize_workspace(tabs, active_tab_id, closed_tabs \\ [], ai_panel_open \\ false)
      when is_list(tabs) and is_list(closed_tabs) do
    query_tabs =
      tabs
      |> Enum.filter(&(Map.get(&1, :kind, :query) == :query))
      |> Enum.map(&serialize_tab/1)

    active_query_id =
      if Enum.any?(query_tabs, &(&1.id == active_tab_id)),
        do: active_tab_id,
        else: List.first(query_tabs) && List.first(query_tabs).id

    normalized_closed =
      closed_tabs
      |> Enum.take(@max_closed_tabs)
      |> Enum.map(&serialize_closed_tab/1)

    %{
      active_tab_id: active_query_id,
      tabs: query_tabs,
      closed_tabs: normalized_closed,
      ai_panel_open: ai_panel_open == true
    }
  end

  defp serialize_closed_tab(tab) do
    tab
    |> serialize_tab()
    |> Map.put(:closed_at, to_string(Map.get(tab, :closed_at) || current_local_iso()))
  end

  defp serialize_tab(tab) do
    {cur_r, cur_c} =
      case Map.get(tab, :cursor) do
        {r, c} when is_integer(r) and is_integer(c) -> {max(0, r), max(0, c)}
        _ -> {0, 0}
      end

    ai_messages =
      tab
      |> Map.get(:ai_messages, [])
      |> Enum.reject(&(Map.get(&1, :status) == :running))
      |> Enum.take(-40)
      |> Enum.map(&serialize_ai_message/1)

    %{
      id: to_string(Map.get(tab, :id) || "tab_1"),
      name: to_string(Map.get(tab, :name) || "Query"),
      profile_id: Map.get(tab, :profile_id),
      content: to_string(Map.get(tab, :content) || ""),
      cursor: {cur_r, cur_c},
      ai_session_id: Map.get(tab, :ai_session_id),
      ai_session_provider: normalize_session_provider(Map.get(tab, :ai_session_provider)),
      ai_applied_msg_id: Map.get(tab, :ai_applied_msg_id),
      ai_messages: ai_messages
    }
  end

  defp serialize_ai_message(msg) do
    %{
      id: to_string(Map.get(msg, :id) || ""),
      prompt: to_string(Map.get(msg, :prompt) || ""),
      sql: Map.get(msg, :sql),
      is_read_only: Map.get(msg, :is_read_only, true) != false,
      explanation: Map.get(msg, :explanation),
      error: Map.get(msg, :error),
      status: normalize_msg_status(Map.get(msg, :status))
    }
  end

  defp normalize_msg_status(:error), do: :error
  defp normalize_msg_status("error"), do: :error
  defp normalize_msg_status(_), do: :done

  defp normalize_session_provider(p) when p in [:claude, :codex, :agy], do: p
  defp normalize_session_provider("claude"), do: :claude
  defp normalize_session_provider("codex"), do: :codex
  defp normalize_session_provider("agy"), do: :agy
  defp normalize_session_provider(_), do: nil

  defp get_table_name(store) when is_atom(store), do: store
  defp get_table_name(store) when is_pid(store), do: GenServer.call(store, :get_table_name)

  defp load_from_disk(path) do
    if File.exists?(path) do
      with {:ok, content} <- File.read(path),
           {:ok, map} when is_map(map) <- Jason.decode(content) do
        deserialize_workspace(map)
      else
        _ -> %{active_tab_id: nil, tabs: [], closed_tabs: [], ai_panel_open: false}
      end
    else
      %{active_tab_id: nil, tabs: [], closed_tabs: [], ai_panel_open: false}
    end
  end

  defp deserialize_workspace(map) do
    tabs =
      case Map.get(map, "tabs", []) do
        list when is_list(list) -> list |> Enum.filter(&is_map/1) |> Enum.map(&deserialize_tab/1)
        _ -> []
      end

    closed_tabs =
      case Map.get(map, "closed_tabs", []) do
        list when is_list(list) ->
          list
          |> Enum.filter(&is_map/1)
          |> Enum.map(&deserialize_closed_tab/1)
          |> Enum.take(@max_closed_tabs)

        _ ->
          []
      end

    active_id = Map.get(map, "active_tab_id")
    ai_panel_open = Map.get(map, "ai_panel_open", false) == true

    %{
      active_tab_id: active_id,
      tabs: tabs,
      closed_tabs: closed_tabs,
      ai_panel_open: ai_panel_open
    }
  end

  defp deserialize_closed_tab(t) do
    t
    |> deserialize_tab()
    |> Map.put(:closed_at, to_string(Map.get(t, "closed_at") || ""))
  end

  defp deserialize_tab(t) do
    cursor =
      case Map.get(t, "cursor") do
        [r, c] when is_integer(r) and is_integer(c) -> {max(0, r), max(0, c)}
        _ -> {0, 0}
      end

    messages =
      case Map.get(t, "ai_messages") do
        list when is_list(list) ->
          list
          |> Enum.filter(&is_map/1)
          |> Enum.map(&deserialize_ai_message/1)

        _ ->
          []
      end

    %{
      id: to_string(Map.get(t, "id") || "tab_1"),
      name: to_string(Map.get(t, "name") || "Query"),
      profile_id: Map.get(t, "profile_id"),
      content: to_string(Map.get(t, "content") || ""),
      cursor: cursor,
      ai_session_id: Map.get(t, "ai_session_id"),
      ai_session_provider: normalize_session_provider(Map.get(t, "ai_session_provider")),
      ai_applied_msg_id: Map.get(t, "ai_applied_msg_id"),
      ai_messages: messages
    }
  end

  defp deserialize_ai_message(m) do
    %{
      id:
        to_string(
          Map.get(m, "id") || "ai_" <> Integer.to_string(System.unique_integer([:positive]))
        ),
      prompt: to_string(Map.get(m, "prompt") || ""),
      sql: Map.get(m, "sql"),
      is_read_only: Map.get(m, "is_read_only", true) != false,
      explanation: Map.get(m, "explanation"),
      error: Map.get(m, "error"),
      status: normalize_msg_status(Map.get(m, "status"))
    }
  end

  defp schedule_save(state) do
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
    path = state.workspace_path
    dir = Path.dirname(path)
    File.mkdir_p!(dir)

    if Path.basename(dir) == ".strata" do
      _ = File.chmod(dir, 0o700)
    end

    ws =
      case :ets.lookup(state.table, :workspace) do
        [{:workspace, %{} = w}] -> w
        _ -> %{active_tab_id: nil, tabs: [], closed_tabs: [], ai_panel_open: false}
      end

    json_map = %{
      "active_tab_id" => ws.active_tab_id,
      "ai_panel_open" => Map.get(ws, :ai_panel_open, false) == true,
      "tabs" => Enum.map(ws.tabs, &tab_to_json/1),
      "closed_tabs" => Enum.map(Map.get(ws, :closed_tabs, []), &closed_tab_to_json/1)
    }

    tmp_path = "#{path}.tmp.#{System.unique_integer([:positive])}"

    case Jason.encode(json_map, pretty: true) do
      {:ok, json} ->
        File.write!(tmp_path, json)
        _ = File.chmod(tmp_path, 0o600)
        File.rename!(tmp_path, path)
        _ = File.chmod(path, 0o600)

      {:error, reason} ->
        Logger.error("Failed to encode workspace: #{inspect(reason)}")
    end
  rescue
    e ->
      Logger.error("Error persisting workspace: #{inspect(e)}")
      :error
  end

  defp closed_tab_to_json(t) do
    t
    |> tab_to_json()
    |> Map.put("closed_at", to_string(Map.get(t, :closed_at) || ""))
  end

  defp tab_to_json(t) do
    {r, c} = t.cursor

    %{
      "id" => t.id,
      "name" => t.name,
      "profile_id" => t.profile_id,
      "content" => t.content,
      "cursor" => [r, c],
      "ai_session_id" => t.ai_session_id,
      "ai_session_provider" =>
        case Map.get(t, :ai_session_provider) do
          p when p in [:claude, :codex, :agy] -> Atom.to_string(p)
          _ -> nil
        end,
      "ai_applied_msg_id" => t.ai_applied_msg_id,
      "ai_messages" =>
        Enum.map(t.ai_messages, fn m ->
          %{
            "id" => m.id,
            "prompt" => m.prompt,
            "sql" => m.sql,
            "is_read_only" => m.is_read_only,
            "explanation" => m.explanation,
            "error" => m.error,
            "status" => Atom.to_string(m.status)
          }
        end)
    }
  end
end
