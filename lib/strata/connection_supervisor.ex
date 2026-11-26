defmodule Strata.ConnectionSupervisor do
  @moduledoc """
  DynamicSupervisor managing persistent database ConnectionWorker processes,
  indexed via Strata.ConnectionRegistry (mirroring Caudata.ServerSupervisor).
  """
  use DynamicSupervisor
  require Logger

  alias Strata.ConnectionProfile
  alias Strata.ConnectionWorker

  def start_link(init_arg \\ []) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @doc """
  Starts a persistent ConnectionWorker under the supervisor for the given profile.
  """
  @spec start_worker(ConnectionProfile.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def start_worker(%ConnectionProfile{} = profile, opts \\ []) do
    opts = Keyword.put_new(opts, :name, via_tuple(profile.id))
    spec = {ConnectionWorker, {profile, opts}}

    case DynamicSupervisor.start_child(__MODULE__, spec) do
      {:ok, pid} ->
        {:ok, pid}

      {:ok, pid, _info} ->
        {:ok, pid}

      {:error, {:already_started, pid}} ->
        {:ok, pid}

      {:error, reason} ->
        Logger.error("Failed to start ConnectionWorker for #{profile.id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Returns an existing ConnectionWorker pid for `profile.id`, or starts a new one.
  """
  @spec get_or_start_worker(ConnectionProfile.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def get_or_start_worker(%ConnectionProfile{} = profile, opts \\ []) do
    case lookup_worker(profile.id) do
      {:ok, pid} ->
        if Process.alive?(pid) do
          {:ok, pid}
        else
          start_worker(profile, opts)
        end

      {:error, :not_found} ->
        start_worker(profile, opts)
    end
  end

  @doc """
  Stops the ConnectionWorker process for the given profile ID.
  """
  @spec stop_worker(String.t()) :: :ok | {:error, :not_found}
  def stop_worker(profile_id) when is_binary(profile_id) do
    case lookup_worker(profile_id) do
      {:ok, pid} ->
        _ = DynamicSupervisor.terminate_child(__MODULE__, pid)
        :ok

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  @doc """
  Looks up the active ConnectionWorker pid by profile ID.
  """
  @spec lookup_worker(String.t()) :: {:ok, pid()} | {:error, :not_found}
  def lookup_worker(profile_id) when is_binary(profile_id) do
    if Process.whereis(Strata.ConnectionRegistry) do
      case Registry.lookup(Strata.ConnectionRegistry, profile_id) do
        [{pid, _value}] ->
          if Process.alive?(pid), do: {:ok, pid}, else: {:error, :not_found}

        [] ->
          {:error, :not_found}
      end
    else
      {:error, :not_found}
    end
  end

  @doc """
  Returns `{:via, Registry, ...}` tuple for naming a ConnectionWorker.
  """
  def via_tuple(profile_id) when is_binary(profile_id) do
    {:via, Registry, {Strata.ConnectionRegistry, profile_id}}
  end

  @impl true
  def init(_init_arg) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end
end
