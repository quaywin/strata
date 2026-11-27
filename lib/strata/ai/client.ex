defmodule Strata.AI.Client do
  @moduledoc """
  Unified AI assistant client routing SQL Query Editor (`:sql`) and CLI health check (`:ping`)
  tasks through the configured local CLI (`claude`, `codex`, `agy`).
  """

  alias Strata.AI.CLIRunner
  alias Strata.AI.Prompts
  alias Strata.AISettings

  @type sql_result :: %{
          sql: String.t(),
          is_read_only: boolean(),
          explanation: String.t(),
          session_id: String.t() | nil
        }

  @doc """
  Generates a structured SQL Query Editor payload (`sql`, `is_read_only`, `explanation`).
  """
  @spec generate_sql(AISettings.t(), map(), String.t(), keyword()) ::
          {:ok, sql_result()} | {:error, String.t()}
  def generate_sql(%AISettings{} = settings, context, user_request, opts \\ []) do
    prompt = Prompts.build_sql_prompt(context, user_request)

    with {:ok, payload, session_id} <- run_task(settings, :sql, prompt, opts) do
      {:ok, normalize_sql_payload(payload, session_id)}
    end
  end

  @doc """
  Verifies that the configured CLI is installed, authenticated, and returns structured JSON.
  """
  @spec test_cli(AISettings.t(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def test_cli(%AISettings{} = settings, opts \\ []) do
    prompt = Prompts.build_ping_prompt()

    with {:ok, _payload, _session_id} <-
           run_task(
             %{settings | keep_conversation: false},
             :ping,
             prompt,
             Keyword.put_new(opts, :timeout_ms, 25_000)
           ) do
      {:ok, "⚡ #{AISettings.cli_command(settings.provider)} CLI is ready!"}
    end
  end

  @doc """
  Builds `{executable, args, meta}` for the given provider and task type.
  Exposed for deterministic unit testing.
  """
  @spec build_command(AISettings.t(), atom(), String.t(), keyword()) ::
          {:ok, {String.t(), [String.t()], map()}} | {:error, String.t()}
  def build_command(%AISettings{} = settings, task_type, prompt, opts \\ []) do
    provider = AISettings.normalize_provider(settings.provider)
    exe_override = Keyword.get(opts, :executable)

    case exe_override || AISettings.find_executable(provider) do
      nil ->
        cmd = AISettings.cli_command(provider)
        {:error, "'#{cmd}' CLI was not found in PATH"}

      executable ->
        schema_json = Prompts.json_schema(task_type)
        model = String.trim(to_string(settings.model || ""))
        session_id = normalize_session_id(Keyword.get(opts, :session_id))
        keep_conv? = settings.keep_conversation != false

        {args, meta} =
          case provider do
            :claude ->
              base = [
                "-p",
                prompt,
                "--tools",
                "",
                "--output-format",
                "json",
                "--json-schema",
                schema_json
              ]

              base = if model != "", do: base ++ ["--model", model], else: base

              base =
                if is_binary(session_id) and keep_conv? do
                  base ++ ["--resume", session_id]
                else
                  base
                end

              {base, %{provider: :claude, cleanup_files: []}}

            :codex ->
              uniq = Integer.to_string(System.unique_integer([:positive]))
              tmp_dir = System.tmp_dir!()
              schema_path = Path.join(tmp_dir, "strata_codex_schema_#{uniq}.json")
              out_path = Path.join(tmp_dir, "strata_codex_out_#{uniq}.json")
              File.write!(schema_path, schema_json)

              flags = [
                "--skip-git-repo-check",
                "--json",
                "--output-schema",
                schema_path,
                "-o",
                out_path
              ]

              flags = if model != "", do: flags ++ ["-m", model], else: flags

              args =
                if is_binary(session_id) and keep_conv? do
                  ["exec", "resume"] ++ flags ++ [session_id, prompt]
                else
                  ephemeral_flag = if keep_conv?, do: [], else: ["--ephemeral"]
                  ["exec"] ++ ephemeral_flag ++ flags ++ [prompt]
                end

              {args,
               %{
                 provider: :codex,
                 output_file: out_path,
                 cleanup_files: [schema_path, out_path]
               }}

            :agy ->
              base = [
                "-p",
                prompt,
                "--disable-slash-commands",
                "--output-format",
                "json",
                "--json-schema",
                schema_json
              ]

              base = if model != "", do: base ++ ["--model", model], else: base

              base =
                if is_binary(session_id) and keep_conv? do
                  base ++ ["--conversation", session_id]
                else
                  base
                end

              {base, %{provider: :agy, cleanup_files: []}}
          end

        {:ok, {executable, args, meta}}
    end
  end

  @doc """
  Parses CLI stdout (and optional codex output file contents) into `{:ok, payload_map, session_id}`.
  """
  @spec parse_output(atom(), String.t(), keyword()) ::
          {:ok, map(), String.t() | nil} | {:error, String.t()}
  def parse_output(:claude, output, _opts) do
    with {:ok, envelope} <- decode_json_envelope(output) do
      if Map.get(envelope, "is_error") == true do
        msg = Map.get(envelope, "result") || Map.get(envelope, "error") || "Claude CLI error"
        {:error, to_string(msg)}
      else
        session_id = normalize_session_id(Map.get(envelope, "session_id"))

        payload =
          cond do
            is_map(Map.get(envelope, "structured_output")) ->
              {:ok, Map.get(envelope, "structured_output")}

            is_map(Map.get(envelope, "result")) ->
              {:ok, Map.get(envelope, "result")}

            is_binary(Map.get(envelope, "result")) ->
              extract_json_object(Map.get(envelope, "result"))

            true ->
              {:error, "Claude response missing structured_output/result"}
          end

        case payload do
          {:ok, map} -> {:ok, map, session_id}
          {:error, reason} -> {:error, reason}
        end
      end
    end
  end

  def parse_output(:agy, output, _opts) do
    with {:ok, envelope} <- decode_json_envelope(output) do
      status = Map.get(envelope, "status")

      if is_binary(status) and String.upcase(status) not in ["SUCCESS", "OK"] do
        msg =
          Map.get(envelope, "error") || Map.get(envelope, "response") ||
            "Agy CLI failed (#{status})"

        {:error, to_string(msg)}
      else
        session_id =
          normalize_session_id(
            Map.get(envelope, "conversation_id") ||
              Map.get(envelope, "session_id") ||
              Map.get(envelope, "conversationId")
          )

        payload =
          cond do
            is_map(Map.get(envelope, "structured_output")) ->
              {:ok, Map.get(envelope, "structured_output")}

            is_map(Map.get(envelope, "response")) ->
              {:ok, Map.get(envelope, "response")}

            is_binary(Map.get(envelope, "response")) ->
              extract_json_object(Map.get(envelope, "response"))

            is_binary(Map.get(envelope, "result")) ->
              extract_json_object(Map.get(envelope, "result"))

            true ->
              {:error, "Agy response missing structured_output"}
          end

        case payload do
          {:ok, map} -> {:ok, map, session_id}
          {:error, reason} -> {:error, reason}
        end
      end
    end
  end

  def parse_output(:codex, output, opts) do
    events =
      output
      |> String.split("\n", trim: true)
      |> Enum.reduce([], fn line, acc ->
        case Jason.decode(String.trim(line)) do
          {:ok, map} when is_map(map) -> [map | acc]
          _ -> acc
        end
      end)
      |> Enum.reverse()

    session_id =
      Enum.find_value(events, fn
        %{"type" => "thread.started", "thread_id" => id} -> normalize_session_id(id)
        %{"thread_id" => id} -> normalize_session_id(id)
        %{"session_id" => id} -> normalize_session_id(id)
        _ -> nil
      end)

    error_event =
      Enum.find_value(events, fn
        %{"type" => "error", "message" => msg} -> to_string(msg)
        %{"type" => "turn.failed", "error" => %{"message" => msg}} -> to_string(msg)
        _ -> nil
      end)

    out_text = Keyword.get(opts, :output_file_content)

    raw_payload_text =
      cond do
        is_binary(out_text) and String.trim(out_text) != "" ->
          out_text

        true ->
          events
          |> Enum.reverse()
          |> Enum.find_value(fn
            %{"type" => "item.completed", "item" => %{"type" => "agent_message", "text" => txt}} ->
              txt

            %{"msg" => %{"type" => "agent_message", "message" => txt}} ->
              txt

            _ ->
              nil
          end)
      end

    cond do
      is_binary(raw_payload_text) ->
        case extract_json_object(raw_payload_text) do
          {:ok, map} -> {:ok, map, session_id}
          {:error, reason} -> {:error, reason}
        end

      is_binary(error_event) ->
        {:error, error_event}

      true ->
        {:error, summarize_cli_error(output)}
    end
  end

  defp run_task(%AISettings{} = settings, task_type, prompt, opts) do
    runner = Keyword.get(opts, :runner, &CLIRunner.run/3)
    timeout_ms = Keyword.get(opts, :timeout_ms, 45_000)

    with {:ok, {executable, args, meta}} <- build_command(settings, task_type, prompt, opts) do
      try do
        case runner.(executable, args, timeout_ms: timeout_ms) do
          {:ok, stdout} ->
            file_content = read_optional_file(Map.get(meta, :output_file))
            parse_output(meta.provider, stdout, output_file_content: file_content)

          {:error, :timeout} ->
            {:error, "AI CLI timed out after #{div(timeout_ms, 1000)}s"}

          {:error, {:exit_status, code, output}} ->
            file_content = read_optional_file(Map.get(meta, :output_file))

            case parse_output(meta.provider, output, output_file_content: file_content) do
              {:ok, _, _} = ok -> ok
              {:error, msg} -> {:error, "CLI exited (#{code}): #{msg}"}
            end

          {:error, reason} ->
            {:error, Strata.Formatter.format_error(reason)}
        end
      after
        Enum.each(Map.get(meta, :cleanup_files, []), &File.rm/1)
      end
    end
  end

  defp read_optional_file(nil), do: nil

  defp read_optional_file(path) do
    case File.read(path) do
      {:ok, content} -> content
      _ -> nil
    end
  end

  defp decode_json_envelope(output) when is_binary(output) do
    trimmed = String.trim(output)

    case Jason.decode(trimmed) do
      {:ok, map} when is_map(map) ->
        {:ok, map}

      _ ->
        # Some CLIs print warnings/logs before or after the JSON line
        trimmed
        |> String.split("\n", trim: true)
        |> Enum.reverse()
        |> Enum.find_value(fn line ->
          case Jason.decode(String.trim(line)) do
            {:ok, map} when is_map(map) -> {:ok, map}
            _ -> nil
          end
        end)
        |> case do
          {:ok, map} -> {:ok, map}
          nil -> {:error, summarize_cli_error(output)}
        end
    end
  end

  defp extract_json_object(text) when is_binary(text) do
    cleaned =
      text
      |> String.trim()
      |> strip_markdown_fence()

    case Jason.decode(cleaned) do
      {:ok, map} when is_map(map) ->
        {:ok, map}

      _ ->
        case Regex.run(~r/\{.*\}/s, cleaned) do
          [json_slice] ->
            case Jason.decode(json_slice) do
              {:ok, map} when is_map(map) -> {:ok, map}
              _ -> {:error, "Could not parse JSON object from AI output"}
            end

          _ ->
            {:error, "AI output did not contain a valid JSON object"}
        end
    end
  end

  defp strip_markdown_fence(text) do
    text
    |> String.replace(~r/\A```(?:json|sql)?\s*/i, "")
    |> String.replace(~r/\s*```\z/, "")
    |> String.trim()
  end

  defp summarize_cli_error(output) do
    trimmed = String.trim(to_string(output || ""))

    if trimmed == "" do
      "Empty response from AI CLI"
    else
      trimmed
      |> String.split("\n", trim: true)
      |> List.last()
      |> String.slice(0, 180)
    end
  end

  defp normalize_session_id(id) when is_binary(id) do
    trimmed = String.trim(id)
    if trimmed == "", do: nil, else: trimmed
  end

  defp normalize_session_id(_), do: nil

  defp normalize_sql_payload(payload, session_id) do
    sql =
      payload
      |> Map.get("sql", "")
      |> to_string()
      |> strip_markdown_fence()
      |> String.trim()

    is_read_only =
      case Map.get(payload, "is_read_only") do
        val when is_boolean(val) -> val
        _ -> read_only_sql?(sql)
      end

    %{
      sql: sql,
      is_read_only: is_read_only,
      explanation: to_string(Map.get(payload, "explanation") || "AI SQL generated"),
      session_id: session_id
    }
  end

  defp read_only_sql?(sql) do
    trimmed = String.upcase(String.trim_leading(sql))
    String.starts_with?(trimmed, ["SELECT", "WITH", "EXPLAIN", "SHOW", "PRAGMA"])
  end
end
