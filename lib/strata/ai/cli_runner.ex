defmodule Strata.AI.CLIRunner do
  @moduledoc """
  Non-blocking subprocess runner built on Erlang `Port` + `/bin/sh` (`exec "$0" "$@" </dev/null`).
  Avoids shell interpolation, closes stdin immediately so headless CLIs never hang waiting
  on EOF, supports timeouts, and notifies callers on cancel/completion.
  """

  @default_timeout_ms 45_000

  @doc """
  Runs `executable` with `args` synchronously inside the calling process, collecting
  combined stdout/stderr output up to `timeout_ms`.

  Returns `{:ok, output}`, `{:error, {:exit_status, code, output}}`, or `{:error, :timeout}`.
  """
  @spec run(String.t(), [String.t()], keyword()) ::
          {:ok, String.t()}
          | {:error, {:exit_status, non_neg_integer(), String.t()} | :timeout | term()}
  def run(executable, args, opts \\ []) when is_binary(executable) and is_list(args) do
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
    cd = Keyword.get(opts, :cd)

    port_opts =
      [
        {:args, ["-c", ~s(exec "$0" "$@" </dev/null), executable | args]},
        :binary,
        :exit_status,
        :stderr_to_stdout,
        :use_stdio
      ]
      |> maybe_add_cd(cd)

    port = Port.open({:spawn_executable, "/bin/sh"}, port_opts)
    os_pid = port_os_pid(port)
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    collect_loop(port, os_pid, deadline, [])
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp maybe_add_cd(opts, cd) when is_binary(cd) and cd != "", do: [{:cd, cd} | opts]
  defp maybe_add_cd(opts, _), do: opts

  defp port_os_pid(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} -> pid
      _ -> nil
    end
  end

  defp collect_loop(port, os_pid, deadline, chunks) do
    remaining = max(0, deadline - System.monotonic_time(:millisecond))

    receive do
      {^port, {:data, chunk}} ->
        collect_loop(port, os_pid, deadline, [chunk | chunks])

      {^port, {:exit_status, 0}} ->
        {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary()}

      {^port, {:exit_status, code}} ->
        output = chunks |> Enum.reverse() |> IO.iodata_to_binary()
        {:error, {:exit_status, code, output}}
    after
      remaining ->
        cleanup_port(port, os_pid)
        {:error, :timeout}
    end
  end

  defp cleanup_port(port, os_pid) do
    try do
      Port.close(port)
    catch
      _, _ -> :ok
    end

    if is_integer(os_pid) do
      System.cmd("kill", ["-TERM", Integer.to_string(os_pid)], stderr_to_stdout: true)
    end

    :ok
  rescue
    _ -> :ok
  end
end
