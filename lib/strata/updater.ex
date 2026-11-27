defmodule Strata.Updater do
  @moduledoc """
  Self-update engine for Strata.

  Queries GitHub Releases for `quaywin/strata` (or a configured repository),
  compares semantic versions using the same normalization rules as `mix.exs`,
  downloads the platform-specific Burrito binary, verifies its executable header
  (and SHA-256 digest when provided), and atomically replaces the binary on disk.
  """

  @default_repo "quaywin/strata"
  @default_api_base "https://api.github.com"
  @binary_name "strata"

  @type target :: :macos_aarch64 | :macos_x86_64 | :linux_x86_64 | :linux_aarch64
  @type update_status :: :update_available | :up_to_date | :ahead

  @type release_info :: %{
          status: update_status(),
          current_version: String.t(),
          latest_version: String.t(),
          tag_name: String.t(),
          release_name: String.t(),
          release_url: String.t(),
          release_notes: String.t(),
          published_at: String.t() | nil,
          target: target() | nil,
          asset_name: String.t() | nil,
          download_url: String.t() | nil,
          asset_size: non_neg_integer() | nil,
          asset_digest: String.t() | nil
        }

  @type install_target :: %{
          mode: :burrito | :source,
          binary_path: String.t() | nil,
          target: target() | nil,
          writable?: boolean(),
          reason: String.t() | nil
        }

  @doc """
  Returns the configured GitHub repository (`owner/repo`).
  """
  @spec repo(keyword()) :: String.t()
  def repo(opts \\ []) do
    Keyword.get(opts, :repo) || System.get_env("STRATA_UPDATE_REPO") || @default_repo
  end

  @doc """
  Normalizes a version or release tag string into a `Version`-parseable SemVer string.
  Mirrors `mix.exs` and `.github/workflows/release.yml` (e.g., `"v0.1.09"` -> `"0.1.9"`).
  """
  @spec normalize_semver(String.t() | nil) :: String.t() | nil
  def normalize_semver(nil), do: nil

  def normalize_semver(raw) when is_binary(raw) do
    vsn = raw |> String.trim() |> String.trim_leading("v")

    if vsn == "" do
      nil
    else
      case Version.parse(vsn) do
        {:ok, _} ->
          vsn

        :error ->
          {core, suffix} =
            case String.split(vsn, ~r/(?=[+-])/, parts: 2) do
              [c, s] -> {c, s}
              [c] -> {c, ""}
            end

          clean_core =
            core
            |> String.split(".")
            |> Enum.map(&Regex.replace(~r/^0+(\d)/, &1, "\\1"))
            |> Enum.join(".")

          candidate = clean_core <> suffix

          case Version.parse(candidate) do
            {:ok, _} -> candidate
            :error -> nil
          end
      end
    end
  end

  @doc """
  Compares two version strings after SemVer normalization.
  Returns `:lt` when `current < latest`, `:eq` when equal, or `:gt` when `current > latest`.
  """
  @spec compare_versions(String.t(), String.t()) ::
          :lt | :eq | :gt | {:error, :invalid_version}
  def compare_versions(current, latest) when is_binary(current) and is_binary(latest) do
    with norm_cur when is_binary(norm_cur) <- normalize_semver(current),
         norm_lat when is_binary(norm_lat) <- normalize_semver(latest),
         {:ok, cur_v} <- Version.parse(norm_cur),
         {:ok, lat_v} <- Version.parse(norm_lat) do
      Version.compare(cur_v, lat_v)
    else
      _ -> {:error, :invalid_version}
    end
  end

  @doc """
  Detects the current OS/architecture target atom matching Burrito release asset names.
  """
  @spec detect_target() :: {:ok, target()} | {:error, String.t()}
  def detect_target do
    os = :os.type()
    arch = :erlang.system_info(:system_architecture) |> to_string()
    detect_target(os, arch)
  end

  @doc """
  Detects target atom from explicit OS tuple and architecture string.
  """
  @spec detect_target(term(), String.t()) :: {:ok, target()} | {:error, String.t()}
  def detect_target({:unix, :darwin}, arch) when is_binary(arch) do
    if String.contains?(arch, ["aarch64", "arm64"]) do
      {:ok, :macos_aarch64}
    else
      {:ok, :macos_x86_64}
    end
  end

  def detect_target({:unix, :linux}, arch) when is_binary(arch) do
    cond do
      String.contains?(arch, ["x86_64", "amd64"]) -> {:ok, :linux_x86_64}
      String.contains?(arch, ["aarch64", "arm64"]) -> {:ok, :linux_aarch64}
      true -> {:error, "Unsupported Linux architecture: #{arch}"}
    end
  end

  def detect_target(os, arch) do
    {:error, "Unsupported platform: #{inspect(os)} (#{arch})"}
  end

  @doc """
  Returns the release asset filename for the given target atom.
  """
  @spec asset_name(target() | nil) :: String.t() | nil
  def asset_name(nil), do: nil
  def asset_name(target) when is_atom(target), do: "#{@binary_name}_#{target}"

  @doc """
  Returns whether the app is currently running inside a Burrito standalone binary.
  """
  @spec burrito_mode?() :: boolean()
  def burrito_mode?, do: System.get_env("__BURRITO") != nil

  @doc """
  Inspects the active installation target to determine if in-place binary updates are supported.
  """
  @spec install_target(keyword()) :: install_target()
  def install_target(opts \\ []) do
    target =
      case Keyword.get(opts, :target) do
        t when is_atom(t) and not is_nil(t) ->
          t

        _ ->
          case detect_target() do
            {:ok, t} -> t
            {:error, _} -> nil
          end
      end

    explicit_bin = Keyword.get(opts, :binary_path)
    burrito_bin = System.get_env("__BURRITO_BIN_PATH")
    burrito? = Keyword.get(opts, :burrito?, burrito_mode?())

    cond do
      is_binary(explicit_bin) and explicit_bin != "" ->
        build_burrito_target(explicit_bin, target)

      burrito? and is_binary(burrito_bin) and burrito_bin != "" ->
        build_burrito_target(burrito_bin, target)

      burrito? ->
        case System.find_executable(@binary_name) do
          nil ->
            %{
              mode: :burrito,
              binary_path: nil,
              target: target,
              writable?: false,
              reason:
                "Cannot locate running strata executable path (__BURRITO_BIN_PATH is unset)."
            }

          path ->
            build_burrito_target(path, target)
        end

      true ->
        installed = System.find_executable(@binary_name)

        %{
          mode: :source,
          binary_path: installed,
          target: target,
          writable?: false,
          reason:
            "Running from source (Mix). Update via `git pull && mix deps.get` or install standalone binary with `install.sh`."
        }
    end
  end

  defp build_burrito_target(path, target) do
    expanded = Path.expand(path)
    writable? = path_writable?(expanded)

    reason =
      if writable? do
        nil
      else
        "No write permission for #{Path.dirname(expanded)} (try updating with elevated permissions or reinstall to ~/.local/bin)."
      end

    %{
      mode: :burrito,
      binary_path: expanded,
      target: target,
      writable?: writable?,
      reason: reason
    }
  end

  @doc """
  Checks GitHub Releases for a newer version of Strata.

  Options:
  - `:current_version` - override current version string (default: `Strata.CLI.version()`)
  - `:version` - fetch a specific release tag (e.g. `"v0.1.10"`) instead of `/releases/latest`
  - `:repo` - override `"owner/repo"`
  - `:api_base` - override `"https://api.github.com"`
  - `:target` - override target atom
  - `:http_get` - custom `(url, headers) -> {:ok, status, resp_headers, body} | {:error, reason}`
  - `:timeout_ms` - HTTP request timeout in milliseconds (default: `10_000`)
  """
  @spec check_for_update(keyword()) :: {:ok, release_info()} | {:error, String.t()}
  def check_for_update(opts \\ []) do
    current = Keyword.get_lazy(opts, :current_version, fn -> Strata.CLI.version() end)
    repo_slug = repo(opts)
    api_base = Keyword.get(opts, :api_base, @default_api_base) |> String.trim_trailing("/")
    requested_version = Keyword.get(opts, :version)

    target =
      case Keyword.get(opts, :target) do
        t when is_atom(t) and not is_nil(t) ->
          t

        _ ->
          case detect_target() do
            {:ok, t} -> t
            {:error, _} -> nil
          end
      end

    url =
      if is_binary(requested_version) and String.trim(requested_version) != "" do
        tag = normalize_tag(requested_version)
        "#{api_base}/repos/#{repo_slug}/releases/tags/#{URI.encode(tag)}"
      else
        "#{api_base}/repos/#{repo_slug}/releases/latest"
      end

    headers = [
      {"user-agent", "strata/#{current}"},
      {"accept", "application/vnd.github+json"}
    ]

    http_get_fn = Keyword.get(opts, :http_get, &default_http_get/2)

    case http_get_fn.(url, headers) do
      {:ok, 200, _resp_headers, body} ->
        parse_release_response(body, current, target)

      {:ok, 404, _resp_headers, _body} ->
        if is_binary(requested_version) and String.trim(requested_version) != "" do
          {:error, "Release #{normalize_tag(requested_version)} was not found on GitHub."}
        else
          {:error, "No published releases found for #{repo_slug}."}
        end

      {:ok, status, resp_headers, body} when status in [403, 429] ->
        {:error, format_rate_limit_error(status, resp_headers, body)}

      {:ok, status, _resp_headers, body} ->
        {:error, "GitHub API returned HTTP #{status}: #{extract_api_message(body)}"}

      {:error, reason} ->
        {:error, "Failed to check for updates: #{format_error_reason(reason)}"}
    end
  end

  @doc """
  Downloads and atomically installs an update described by `release_info` (or fetches the latest release first).

  Options:
  - `:binary_path` - target binary path override (defaults to `install_target(opts).binary_path`)
  - `:allow_non_burrito` - allow updating `:binary_path` even when `__BURRITO` env is not set (used in tests)
  - `:pre_extract` - whether to run `<binary> --version` after replacing (default: `true`)
  - `:http_download` - custom `(url, dest_path, headers) -> :ok | {:error, reason}`
  """
  @spec apply_update(release_info() | keyword(), keyword()) ::
          {:ok, map()} | {:error, String.t()}
  def apply_update(release_or_opts \\ [], opts \\ [])

  def apply_update(opts, []) when is_list(opts) do
    with {:ok, info} <- check_for_update(opts) do
      apply_update(info, opts)
    end
  end

  def apply_update(%{download_url: nil, asset_name: asset} = info, _opts) do
    target_str = if info.target, do: Atom.to_string(info.target), else: "unknown"

    {:error,
     "No prebuilt binary '#{asset || target_str}' found in release #{info.tag_name}. Please build from source."}
  end

  def apply_update(%{download_url: url} = info, opts) when is_binary(url) do
    install = install_target(opts)

    allow_non_burrito? =
      Keyword.get(opts, :allow_non_burrito, is_binary(Keyword.get(opts, :binary_path)))

    cond do
      install.mode == :source and not allow_non_burrito? ->
        {:error, install.reason}

      is_nil(install.binary_path) ->
        {:error, install.reason}

      not install.writable? ->
        {:error, install.reason}

      true ->
        download_and_replace(info, install.binary_path, opts)
    end
  end

  defp download_and_replace(info, target_path, opts) do
    dir = Path.dirname(target_path)
    File.mkdir_p!(dir)

    uniq = :erlang.unique_integer([:positive])
    tmp_path = Path.join(dir, ".strata.update.#{uniq}.tmp")
    headers = [{"user-agent", "strata/#{info.current_version}"}]
    http_download_fn = Keyword.get(opts, :http_download, &default_http_download/3)

    try do
      with :ok <- http_download_fn.(info.download_url, tmp_path, headers),
           :ok <- verify_downloaded_file(tmp_path, info, opts),
           :ok <- File.chmod(tmp_path, 0o755),
           :ok <- File.rename(tmp_path, target_path) do
        if Keyword.get(opts, :pre_extract, true) do
          _ = pre_extract_binary(target_path)
        end

        {:ok,
         %{
           version: info.latest_version,
           tag_name: info.tag_name,
           binary_path: target_path,
           release_url: info.release_url
         }}
      else
        {:error, reason} ->
          File.rm(tmp_path)
          {:error, format_error_reason(reason)}
      end
    rescue
      e ->
        File.rm(tmp_path)
        {:error, Exception.message(e)}
    end
  end

  @doc """
  Verifies a downloaded binary file's size, optional SHA-256 digest, and native executable header.
  """
  @spec verify_downloaded_file(String.t(), map(), keyword()) :: :ok | {:error, String.t()}
  def verify_downloaded_file(path, info, opts \\ []) do
    with {:ok, %File.Stat{size: size}} <- File.stat(path),
         :ok <- verify_size(size, Map.get(info, :asset_size)),
         :ok <- verify_digest(path, Map.get(info, :asset_digest)),
         :ok <- verify_executable_header(path, Map.get(info, :target), opts) do
      :ok
    else
      {:error, reason} when is_atom(reason) ->
        {:error, "Downloaded file error: #{:file.format_error(reason)}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp verify_size(0, _expected), do: {:error, "Downloaded binary is empty (0 bytes)."}

  defp verify_size(actual, expected) when is_integer(expected) and expected > 0 do
    if actual == expected do
      :ok
    else
      {:error, "Downloaded file size mismatch (expected #{expected} bytes, got #{actual} bytes)."}
    end
  end

  defp verify_size(_actual, _expected), do: :ok

  defp verify_digest(path, "sha256:" <> expected_hex) when byte_size(expected_hex) == 64 do
    actual_hex =
      path
      |> File.stream!(65_536)
      |> Enum.reduce(:crypto.hash_init(:sha256), fn chunk, acc ->
        :crypto.hash_update(acc, chunk)
      end)
      |> :crypto.hash_final()
      |> Base.encode16(case: :lower)

    if actual_hex == String.downcase(expected_hex) do
      :ok
    else
      {:error, "SHA-256 verification failed for downloaded binary."}
    end
  end

  defp verify_digest(_path, _digest), do: :ok

  defp verify_executable_header(path, target, opts) do
    if Keyword.get(opts, :skip_header_check, false) do
      :ok
    else
      case File.open(path, [:read, :binary], fn io -> IO.binread(io, 4) end) do
        {:ok, header} when is_binary(header) ->
          valid? =
            case target do
              t when t in [:macos_aarch64, :macos_x86_64] ->
                header in [
                  <<0xCF, 0xFA, 0xED, 0xFE>>,
                  <<0xFE, 0xED, 0xFA, 0xCF>>,
                  <<0xCA, 0xFE, 0xBA, 0xBE>>
                ]

              t when t in [:linux_x86_64, :linux_aarch64] ->
                header == <<0x7F, "ELF">>

              _ ->
                byte_size(header) == 4
            end

          if valid? do
            :ok
          else
            {:error, "Downloaded file is not a valid #{target || "native"} executable binary."}
          end

        _ ->
          {:error, "Could not read downloaded binary header."}
      end
    end
  end

  defp pre_extract_binary(target_path) do
    System.cmd(target_path, ["--version"], stderr_to_stdout: true)
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp parse_release_response(body, current, target) do
    case Jason.decode(body) do
      {:ok, %{"tag_name" => tag_name} = data} ->
        latest = normalize_semver(tag_name) || String.trim_leading(tag_name, "v")
        expected_asset = asset_name(target)
        assets = Map.get(data, "assets", [])

        matched_asset =
          if expected_asset do
            Enum.find(assets, fn a -> Map.get(a, "name") == expected_asset end)
          end

        status =
          case compare_versions(current, latest) do
            :lt -> :update_available
            :eq -> :up_to_date
            :gt -> :ahead
            {:error, :invalid_version} -> :up_to_date
          end

        {:ok,
         %{
           status: status,
           current_version: normalize_semver(current) || current,
           latest_version: latest,
           tag_name: tag_name,
           release_name: Map.get(data, "name") || tag_name,
           release_url: Map.get(data, "html_url") || "",
           release_notes: Map.get(data, "body") || "",
           published_at: Map.get(data, "published_at"),
           target: target,
           asset_name: expected_asset,
           download_url: matched_asset && Map.get(matched_asset, "browser_download_url"),
           asset_size: matched_asset && Map.get(matched_asset, "size"),
           asset_digest: matched_asset && Map.get(matched_asset, "digest")
         }}

      {:ok, _other} ->
        {:error, "Unexpected GitHub release payload (missing tag_name)."}

      {:error, _reason} ->
        {:error, "Invalid JSON response from GitHub Releases API."}
    end
  end

  defp normalize_tag(version) do
    trimmed = String.trim(version)
    if String.starts_with?(trimmed, "v"), do: trimmed, else: "v" <> trimmed
  end

  defp path_writable?(path) do
    dir = Path.dirname(path)

    cond do
      File.exists?(path) ->
        case File.stat(path) do
          {:ok, %File.Stat{access: access}} when access in [:read_write, :write] ->
            dir_writable?(dir)

          _ ->
            false
        end

      true ->
        dir_writable?(dir)
    end
  end

  defp dir_writable?(dir) do
    case File.stat(dir) do
      {:ok, %File.Stat{access: access}} when access in [:read_write, :write] -> true
      _ -> false
    end
  end

  defp ensure_http_started do
    _ = Application.ensure_all_started(:inets)
    _ = Application.ensure_all_started(:ssl)
    :ok
  end

  defp default_http_get(url, headers) do
    ensure_http_started()
    char_url = String.to_charlist(url)

    char_headers =
      Enum.map(headers, fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)

    http_opts = [
      timeout: 10_000,
      connect_timeout: 5_000,
      autoredirect: true,
      ssl: ssl_options()
    ]

    case :httpc.request(:get, {char_url, char_headers}, http_opts, body_format: :binary) do
      {:ok, {{_http_vsn, status, _reason}, resp_headers, body}} ->
        norm_headers =
          Enum.map(resp_headers, fn {k, v} ->
            {k |> to_string() |> String.downcase(), to_string(v)}
          end)

        {:ok, status, norm_headers, body}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp default_http_download(url, dest_path, headers) do
    ensure_http_started()
    char_url = String.to_charlist(url)

    char_headers =
      Enum.map(headers, fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)

    http_opts = [
      timeout: 120_000,
      connect_timeout: 10_000,
      autoredirect: true,
      ssl: ssl_options()
    ]

    opts = [stream: String.to_charlist(dest_path)]

    case :httpc.request(:get, {char_url, char_headers}, http_opts, opts) do
      {:ok, :saved_to_file} ->
        :ok

      {:ok, {{_http_vsn, status, _reason}, _resp_headers, body}} ->
        {:error, "Download failed with HTTP #{status}: #{extract_api_message(body)}"}

      {:error, reason} ->
        {:error, "Download failed: #{format_error_reason(reason)}"}
    end
  end

  defp ssl_options do
    base = [
      verify: :verify_peer,
      customize_hostname_check: [
        match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
      ]
    ]

    try do
      cacerts = :public_key.cacerts_get()
      [{:cacerts, cacerts} | base]
    catch
      _, _ ->
        case Enum.find(
               ["/etc/ssl/cert.pem", "/etc/ssl/certs/ca-certificates.crt"],
               &File.exists?/1
             ) do
          nil -> [verify: :verify_none]
          ca_file -> [{:cacertfile, String.to_charlist(ca_file)} | base]
        end
    end
  end

  defp format_rate_limit_error(status, resp_headers, body) do
    remaining =
      Enum.find_value(resp_headers, fn
        {"x-ratelimit-remaining", val} -> val
        _ -> nil
      end)

    if remaining == "0" do
      "GitHub API rate limit exceeded (HTTP #{status}). Please wait a few minutes and try again."
    else
      "GitHub API rejected request (HTTP #{status}): #{extract_api_message(body)}"
    end
  end

  defp extract_api_message(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{"message" => msg}} when is_binary(msg) -> msg
      _ -> String.slice(String.trim(body), 0, 120)
    end
  end

  defp extract_api_message(_), do: "Unknown error"

  defp format_error_reason(reason) when is_binary(reason), do: reason

  defp format_error_reason({:failed_connect, _}),
    do: "Could not connect to GitHub (check network)"

  defp format_error_reason(:timeout), do: "Request timed out"
  defp format_error_reason(reason), do: inspect(reason)
end
