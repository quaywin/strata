for var <- ["TARGET_ABI", "TARGET_OS", "TARGET_ARCH"] do
  if System.get_env(var) == "" do
    System.delete_env(var)
  end
end

defmodule Strata.MixProject do
  use Mix.Project

  def project do
    [
      app: :strata,
      version: current_version(),
      elixir: "~> 1.18",
      consolidate_protocols: Mix.env() == :prod,
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      releases: releases()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :ssh],
      mod: {Strata.Application, []}
    ]
  end

  defp host_target do
    case :os.type() do
      {:unix, :darwin} ->
        arch = :erlang.system_info(:system_architecture) |> to_string()

        if String.contains?(arch, "aarch64") or String.contains?(arch, "arm64") do
          :macos_aarch64
        else
          :macos_x86_64
        end

      {:unix, :linux} ->
        arch = :erlang.system_info(:system_architecture) |> to_string()

        cond do
          String.contains?(arch, "x86_64") or String.contains?(arch, "amd64") ->
            :linux_x86_64

          String.contains?(arch, "aarch64") or String.contains?(arch, "arm64") ->
            :linux_aarch64

          true ->
            nil
        end

      _ ->
        nil
    end
  end

  def releases do
    local_erts = to_string(:code.root_dir())
    host = host_target()

    # Precompiled NIFs (ex_ratatui, exqlite) are fetched via TARGET_ARCH/OS/ABI,
    # so skip Burrito's generic RecompileNIFs step which injects macOS linker flags.
    all_targets = [
      macos_aarch64: [os: :darwin, cpu: :aarch64, skip_nifs: true],
      macos_x86_64: [os: :darwin, cpu: :x86_64, skip_nifs: true],
      linux_x86_64: [os: :linux, cpu: :x86_64, skip_nifs: true]
    ]

    all_targets =
      Enum.map(all_targets, fn {name, opts} ->
        # On Linux, keep Burrito's precompiled musl ERTS so musl NIFs (ex_ratatui, exqlite)
        # match beam.smp instead of mixing host glibc ERTS with musl NIFs.
        if name == host and name != :linux_x86_64 do
          {name, Keyword.put(opts, :custom_erts, local_erts)}
        else
          {name, opts}
        end
      end)

    targets = selected_targets(all_targets, host)

    [
      strata: [
        include_executables_for: [:unix],
        strip_beams: true,
        exclude_apps: [:wx, :observer, :debugger, :et, :reltool, :megaco, :eunit, :sasl, :mnesia],
        steps: [:assemble, &verify_burrito_nifs/1, &Burrito.wrap/1],
        burrito: [
          targets: targets,
          extra_steps: [
            patch: [post: [Strata.Release.SyncOTPNIFs]]
          ]
        ]
      ]
    ]
  end

  defp selected_targets(all_targets, host) do
    case System.get_env("BURRITO_TARGET") do
      target when target in ["macos_aarch64", "macos"] ->
        Keyword.take(all_targets, [:macos_aarch64])

      "macos_x86_64" ->
        Keyword.take(all_targets, [:macos_x86_64])

      target when target in ["linux_x86_64", "linux"] ->
        Keyword.take(all_targets, [:linux_x86_64])

      "all" ->
        all_targets

      nil ->
        if Keyword.has_key?(all_targets, host) do
          Keyword.take(all_targets, [host])
        else
          all_targets
        end

      other ->
        Mix.raise("Unsupported BURRITO_TARGET=#{inspect(other)}")
    end
  end

  defp verify_burrito_nifs(release) do
    target_os = resolve_target_os()

    case target_os do
      :linux ->
        Application.put_env(:burrito, :erts_resolver, Strata.Release.LinuxERTSResolver)
        verify_ex_ratatui_linux_nif(release)
        verify_exqlite_nif(release, :linux)

      :darwin ->
        verify_ex_ratatui_darwin_nif(release)
        verify_exqlite_nif(release, :darwin)

      _ ->
        release
    end
  end

  defp resolve_target_os do
    case System.get_env("BURRITO_TARGET") do
      target when target in ["linux", "linux_x86_64"] ->
        :linux

      target when target in ["macos", "macos_aarch64", "macos_x86_64"] ->
        :darwin

      _ ->
        case host_target() do
          t when t in [:linux_x86_64, :linux_aarch64] -> :linux
          t when t in [:macos_aarch64, :macos_x86_64] -> :darwin
          _ -> nil
        end
    end
  end

  defp verify_ex_ratatui_linux_nif(release) do
    prev = System.get_env("BURRITO_TARGET")
    System.put_env("BURRITO_TARGET", "linux")

    try do
      ExRatatui.Burrito.verify_linux_nif(release)
    after
      if prev,
        do: System.put_env("BURRITO_TARGET", prev),
        else: System.delete_env("BURRITO_TARGET")
    end
  end

  defp verify_ex_ratatui_darwin_nif(release) do
    {_otp_app, relative_path} = ExRatatui.Native.load_from()
    so_paths = Path.wildcard(Path.join(release.path, "lib/ex_ratatui-*/#{relative_path}.so"))

    if so_paths == [] do
      Mix.raise("no ex_ratatui NIF found at #{release.path}/lib/ex_ratatui-*/#{relative_path}.so")
    end

    Enum.each(so_paths, &verify_macho_binary!/1)
    release
  end

  defp verify_exqlite_nif(release, target_os) do
    so_paths = Path.wildcard(Path.join(release.path, "lib/exqlite-*/priv/sqlite3_nif.so"))

    if so_paths == [] do
      Mix.raise("no exqlite NIF found at #{release.path}/lib/exqlite-*/priv/sqlite3_nif.so")
    end

    Enum.each(so_paths, fn so_path ->
      case target_os do
        :linux -> verify_linux_musl_binary!(so_path)
        :darwin -> verify_macho_binary!(so_path)
      end
    end)

    release
  end

  defp verify_linux_musl_binary!(so_path) do
    bytes = File.read!(so_path)

    unless match?(<<0x7F, "ELF", _::binary>>, bytes) do
      Mix.raise("""
      #{Path.relative_to_cwd(so_path)} is not a Linux ELF binary.
      Set TARGET_ARCH=x86_64 TARGET_OS=linux TARGET_ABI=musl and rebuild dependencies before releasing.
      """)
    end

    if String.contains?(bytes, "libc.so.6") or String.contains?(bytes, "GLIBC_") do
      Mix.raise("""
      #{Path.relative_to_cwd(so_path)} is linked against glibc, but Burrito's Linux wrapper runs musl.
      Rebuild with:
          TARGET_ARCH=x86_64 TARGET_OS=linux TARGET_ABI=musl BURRITO_TARGET=linux_x86_64 MIX_ENV=prod mix release --overwrite
      """)
    end
  end

  defp verify_macho_binary!(so_path) do
    bytes = File.read!(so_path)

    is_macho =
      match?(<<0xCF, 0xFA, 0xED, 0xFE, _::binary>>, bytes) or
        match?(<<0xFE, 0xED, 0xFA, 0xCF, _::binary>>, bytes) or
        match?(<<0xCA, 0xFE, 0xBA, 0xBE, _::binary>>, bytes)

    unless is_macho do
      Mix.raise("#{Path.relative_to_cwd(so_path)} is not a macOS Mach-O binary.")
    end
  end

  defp current_version do
    base = "0.1.0"
    version_from_env() || version_from_git() || base
  end

  defp version_from_env do
    env_version = System.get_env("STRATA_VERSION") || System.get_env("VERSION")
    github_ref = System.get_env("GITHUB_REF_NAME")

    cond do
      env_version && String.trim(env_version) != "" ->
        normalize_semver(env_version)

      github_ref && String.starts_with?(github_ref, "v") ->
        normalize_semver(github_ref)

      true ->
        nil
    end
  end

  defp version_from_git do
    if File.exists?(Path.join(__DIR__, ".git")) && System.find_executable("git") do
      case System.cmd("git", ["describe", "--tags", "--long"],
             cd: __DIR__,
             stderr_to_stdout: true
           ) do
        {output, 0} ->
          output
          |> String.trim()
          |> String.split("-")
          |> Enum.reverse()
          |> case do
            [_git_hash, "0" | rest] ->
              rest |> Enum.reverse() |> Enum.join("-") |> normalize_semver()

            [git_hash, count | rest] ->
              tag = rest |> Enum.reverse() |> Enum.join("-")
              hash = String.trim_leading(git_hash, "g")
              normalize_semver("#{tag}+dev.#{count}.#{hash}")

            _ ->
              nil
          end

        _ ->
          nil
      end
    end
  end

  defp normalize_semver(raw) when is_binary(raw) do
    vsn = raw |> String.trim() |> String.trim_leading("v")

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

  defp deps do
    [
      {:postgrex, "~> 0.23"},
      {:myxql, "~> 0.9"},
      {:exqlite, "~> 0.43"},
      {:jason, "~> 1.4"},
      {:ex_ratatui, "~> 0.21.0"},
      {:phoenix_pubsub, "~> 2.4"},
      {:burrito, "~> 1.5.0", runtime: false}
    ]
  end
end

defmodule Strata.Release.LinuxERTSResolver do
  @moduledoc false

  def do_resolve(%{erts_source: {:precompiled, version: version}} = target) do
    normalized =
      case String.split(version, ".") do
        [major, minor | _rest] -> "#{major}.#{minor}"
        _ -> version
      end

    try do
      apply(Burrito.Util.DefaultERTSResolver, :do_resolve, [target])
    rescue
      _ ->
        apply(Burrito.Util.DefaultERTSResolver, :do_resolve, [
          %{target | erts_source: {:precompiled, version: normalized}}
        ])
    end
  end

  def do_resolve(target) do
    apply(Burrito.Util.DefaultERTSResolver, :do_resolve, [target])
  end
end

defmodule Strata.Release.SyncOTPNIFs do
  @moduledoc false

  def execute(%{work_dir: work_dir, target: %{os: :linux}} = context) do
    lib_dir = Path.join(work_dir, "lib")
    entries = File.ls!(lib_dir)

    for dir <- entries do
      full_dir = Path.join(lib_dir, dir)
      ebin_dir = Path.join(full_dir, "ebin")

      if File.dir?(full_dir) and not File.dir?(ebin_dir) do
        app_prefix = dir |> String.split("-") |> List.first()

        target_dir =
          Enum.find(entries, fn candidate ->
            candidate != dir and
              String.starts_with?(candidate, app_prefix <> "-") and
              File.dir?(Path.join([lib_dir, candidate, "ebin"]))
          end)

        if target_dir do
          target_full = Path.join(lib_dir, target_dir)

          full_dir
          |> Path.join("**/*.so")
          |> Path.wildcard()
          |> Enum.each(fn src_so ->
            rel = Path.relative_to(src_so, full_dir)
            dest_so = Path.join(target_full, rel)
            File.mkdir_p!(Path.dirname(dest_so))
            File.cp!(src_so, dest_so)
          end)

          File.rm_rf!(full_dir)
        end
      end
    end

    context
  end

  def execute(context), do: context
end
