defmodule Strata.SSHTunnel do
  @moduledoc """
  Manages SSH port forwarding using Erlang's :ssh application.
  """
  use GenServer

  alias Strata.SSHProfile

  @doc """
  Starts an SSH tunnel GenServer process.
  Options:
    - `:ssh_profile` - Strata.SSHProfile struct (required)
    - `:target_host` - String target host (default "127.0.0.1")
    - `:target_port` - Integer target port (required)
  """
  def start_link(opts) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Helper to establish a tunnel and return `{:ok, local_port, tunnel_pid}` or `{:error, reason}`.
  """
  def connect(%SSHProfile{} = profile, target_host, target_port) do
    case GenServer.start(__MODULE__,
           ssh_profile: profile,
           target_host: target_host,
           target_port: target_port
         ) do
      {:ok, pid} ->
        case get_port(pid) do
          {:ok, port} ->
            {:ok, port, pid}

          {:error, reason} ->
            GenServer.stop(pid)
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  def get_port(pid) when is_pid(pid) do
    GenServer.call(pid, :get_port)
  end

  def stop(pid) when is_pid(pid) do
    GenServer.stop(pid)
  end

  # GenServer Callbacks

  @impl true
  def init(opts) do
    ssh_profile = Keyword.fetch!(opts, :ssh_profile)
    target_host = Keyword.get(opts, :target_host, "127.0.0.1")
    target_port = Keyword.fetch!(opts, :target_port)

    Application.ensure_all_started(:ssh)

    host_charlist = String.to_charlist(ssh_profile.host)
    port = ssh_profile.port || 22

    ssh_opts = build_ssh_opts(ssh_profile)

    case :ssh.connect(host_charlist, port, ssh_opts, 5000) do
      {:ok, conn_ref} ->
        target_host_charlist = String.to_charlist(target_host)

        case :ssh.tcpip_tunnel_to_server(
               conn_ref,
               {127, 0, 0, 1},
               0,
               target_host_charlist,
               target_port
             ) do
          {:ok, local_port} ->
            {:ok,
             %{
               conn_ref: conn_ref,
               local_port: local_port,
               target_host: target_host,
               target_port: target_port
             }}

          {:error, reason} ->
            :ssh.close(conn_ref)
            {:stop, reason}
        end

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:get_port, _from, state) do
    {:reply, {:ok, state.local_port}, state}
  end

  @impl true
  def terminate(_reason, state) do
    if Map.has_key?(state, :conn_ref) and state.conn_ref != nil do
      :ssh.close(state.conn_ref)
    end

    :ok
  end

  defp build_ssh_opts(%SSHProfile{} = profile) do
    opts = [
      silently_accept_hosts: true,
      user_interaction: false,
      connect_timeout: 5000
    ]

    opts =
      if profile.username && profile.username != "" do
        [{:user, String.to_charlist(profile.username)} | opts]
      else
        opts
      end

    opts =
      if profile.password && profile.password != "" do
        [{:password, String.to_charlist(profile.password)} | opts]
      else
        opts
      end

    expanded_id =
      if is_binary(profile.identity_file) and profile.identity_file != "" do
        Path.expand(profile.identity_file)
      else
        nil
      end

    default_ssh_dir = Path.expand("~/.ssh")

    user_dir =
      cond do
        expanded_id && File.exists?(expanded_id) -> Path.dirname(expanded_id)
        File.dir?(default_ssh_dir) -> default_ssh_dir
        true -> nil
      end

    opts =
      if user_dir do
        [{:user_dir, String.to_charlist(user_dir)} | opts]
      else
        opts
      end

    opts =
      if profile.passphrase && profile.passphrase != "" do
        pass_cl = String.to_charlist(profile.passphrase)

        [
          {:rsa_pass_phrase, pass_cl},
          {:dsa_pass_phrase, pass_cl},
          {:ecdsa_pass_phrase, pass_cl}
          | opts
        ]
      else
        opts
      end

    opts =
      if expanded_id && File.exists?(expanded_id) do
        [
          {:key_cb,
           {Strata.SSHKeyCallback, [identity_file: expanded_id, passphrase: profile.passphrase]}}
          | opts
        ]
      else
        opts
      end

    opts
  end
end
