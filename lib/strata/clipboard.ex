defmodule Strata.Clipboard do
  @moduledoc """
  Cross-platform OS clipboard helper (macOS pbcopy, Linux xclip/xsel/wl-copy, Windows clip),
  bypassed in `:test` environment (mirroring `Caudata.UI.ViewHelper.copy_to_clipboard/1`).
  """

  @env Application.compile_env(:strata, :env, :prod)

  @doc """
  Copies `text` to the system clipboard and, when attached to a TTY, emits an
  OSC 52 sequence so remote sessions (e.g. `herdr`, SSH, tmux) also receive it.
  Returns `:ok` or `{:error, reason}`.
  """
  @spec copy(String.t()) :: :ok | {:error, term()}
  def copy(text) when is_binary(text) do
    if @env == :test do
      Process.put(:strata_test_clipboard, text)
      :ok
    else
      os_res = copy_os_clipboard(text)
      osc_res = write_osc52(text)

      case {os_res, osc_res} do
        {:ok, _} -> :ok
        {_, :ok} -> :ok
        {err, _} -> err
      end
    end
  end

  @doc """
  Encodes `text` as an OSC 52 terminal clipboard escape sequence.
  """
  @spec encode_osc52(String.t(), keyword()) :: String.t()
  def encode_osc52(text, opts \\ []) when is_binary(text) do
    b64 = Base.encode64(text)
    seq = "\e]52;c;" <> b64 <> "\a"

    if Keyword.get(opts, :tmux, false) do
      "\ePtmux;\e" <> seq <> "\e\\"
    else
      seq
    end
  end

  defp write_osc52(text) when byte_size(text) <= 75_000 do
    tmux? = is_binary(System.get_env("TMUX")) and System.get_env("TMUX") != ""
    seq = encode_osc52(text, tmux: tmux?)

    case :file.open(~c"/dev/tty", [:write, :raw, :binary]) do
      {:ok, fd} ->
        res = :file.write(fd, seq)
        :file.close(fd)
        res

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp write_osc52(_text), do: {:error, :osc52_payload_too_large}

  defp copy_os_clipboard(text) do
    case :os.type() do
      {:unix, :darwin} ->
        pipe_to_command("pbcopy", [], text)

      {:unix, :linux} ->
        cond do
          System.find_executable("wl-copy") ->
            pipe_to_command("wl-copy", [], text)

          System.find_executable("xclip") ->
            pipe_to_command("xclip", ["-selection", "clipboard"], text)

          System.find_executable("xsel") ->
            pipe_to_command("xsel", ["--clipboard", "--input"], text)

          true ->
            {:error, :no_clipboard_tool}
        end

      {:win32, _} ->
        pipe_to_command("clip", [], text)

      _ ->
        {:error, :unsupported_os}
    end
  end

  @doc """
  Reads text from the system clipboard. Returns `{:ok, text}` or `{:error, reason}`.
  """
  @spec paste() :: {:ok, String.t()} | {:error, term()}
  def paste do
    if @env == :test do
      {:ok, Process.get(:strata_test_clipboard, "")}
    else
      case :os.type() do
        {:unix, :darwin} ->
          read_from_command("pbpaste", [])

        {:unix, :linux} ->
          cond do
            System.find_executable("wl-paste") ->
              read_from_command("wl-paste", ["--no-newline"])

            System.find_executable("xclip") ->
              read_from_command("xclip", ["-selection", "clipboard", "-o"])

            System.find_executable("xsel") ->
              read_from_command("xsel", ["--clipboard", "--output"])

            true ->
              {:error, :no_clipboard_tool}
          end

        {:win32, _} ->
          read_from_command("powershell", ["-NoProfile", "-Command", "Get-Clipboard"])

        _ ->
          {:error, :unsupported_os}
      end
    end
  end

  defp read_from_command(cmd, args) do
    case System.find_executable(cmd) do
      nil ->
        {:error, {:not_found, cmd}}

      exe ->
        case System.cmd(exe, args, stderr_to_stdout: true) do
          {out, 0} -> {:ok, out}
          {out, _code} -> {:error, String.trim(out)}
        end
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  @doc """
  Pipes `input` to `cmd` cleanly with an exact byte-length EOF (`head -c`) and waits
  for exit status so clipboard utilities (`pbcopy`, `wl-copy`, `xclip`, `xsel`) never
  race with premature port termination.
  """
  def pipe_to_command(cmd, args, input) when is_binary(cmd) and is_list(args) and is_binary(input) do
    case System.find_executable(cmd) do
      nil ->
        {:error, {:not_found, cmd}}

      exe ->
        sh = System.find_executable("sh")
        head = System.find_executable("head")

        if byte_size(input) == 0 do
          if sh do
            script = ~s(exe="$1"; shift; exec "$exe" "$@" </dev/null >/dev/null 2>&1)

            port =
              Port.open({:spawn_executable, sh}, [
                :binary,
                :exit_status,
                :hide,
                args: ["-c", script, "_", exe | args]
              ])

            receive do
              {^port, {:exit_status, 0}} -> :ok
              {^port, {:exit_status, code}} -> {:error, {:exit_status, code}}
            after
              2_000 ->
                Port.close(port)
                {:error, :timeout}
            end
          else
            {:error, {:not_found, "sh"}}
          end
        else
          if sh && head do
            bytes = Integer.to_string(byte_size(input))
            script = ~s(n="$1"; exe="$2"; shift 2; head -c "$n" 2>/dev/null | "$exe" "$@" >/dev/null 2>&1)

            port =
              Port.open({:spawn_executable, sh}, [
                :binary,
                :exit_status,
                :hide,
                args: ["-c", script, "_", bytes, exe | args]
              ])

            Port.command(port, input)

            receive do
              {^port, {:exit_status, 0}} ->
                :ok

              {^port, {:exit_status, code}} ->
                {:error, {:exit_status, code}}
            after
              2_000 ->
                Port.close(port)
                {:error, :timeout}
            end
          else
            port =
              Port.open({:spawn_executable, exe}, [
                :binary,
                :exit_status,
                :hide,
                args: args
              ])

            Port.command(port, input)
            Port.close(port)
            :ok
          end
        end
    end
  rescue
    e -> {:error, Exception.message(e)}
  end
end
