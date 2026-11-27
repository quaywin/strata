defmodule Strata.UpdaterTest do
  use ExUnit.Case, async: true

  alias Strata.Updater

  @macho_magic <<0xCF, 0xFA, 0xED, 0xFE>>
  @elf_magic <<0x7F, "ELF">>

  describe "normalize_semver/1 and compare_versions/2" do
    test "normalizes v-prefixed and zero-padded release tags" do
      assert Updater.normalize_semver("v0.1.09") == "0.1.9"
      assert Updater.normalize_semver("0.1.08") == "0.1.8"
      assert Updater.normalize_semver("v1.2.3+dev.4.abc123") == "1.2.3+dev.4.abc123"
      assert Updater.normalize_semver("") == nil
      assert Updater.normalize_semver(nil) == nil
    end

    test "compares versions accurately after normalization" do
      assert Updater.compare_versions("0.1.9", "v0.1.10") == :lt
      assert Updater.compare_versions("0.1.9", "v0.1.09") == :eq
      assert Updater.compare_versions("0.1.9+dev.3.abc", "v0.1.09") == :eq
      assert Updater.compare_versions("0.2.0", "v0.1.10") == :gt
      assert Updater.compare_versions("invalid", "1.0.0") == {:error, :invalid_version}
    end
  end

  describe "detect_target/2 and asset_name/1" do
    test "maps supported OS and architectures to Burrito asset targets" do
      assert {:ok, :macos_aarch64} =
               Updater.detect_target({:unix, :darwin}, "aarch64-apple-darwin")

      assert {:ok, :macos_x86_64} = Updater.detect_target({:unix, :darwin}, "x86_64-apple-darwin")

      assert {:ok, :linux_x86_64} =
               Updater.detect_target({:unix, :linux}, "x86_64-unknown-linux-gnu")

      assert {:ok, :linux_aarch64} =
               Updater.detect_target({:unix, :linux}, "aarch64-unknown-linux-musl")

      assert {:error, _} = Updater.detect_target({:win32, :nt}, "x86_64")

      assert Updater.asset_name(:macos_aarch64) == "strata_macos_aarch64"
      assert Updater.asset_name(:linux_x86_64) == "strata_linux_x86_64"
      assert Updater.asset_name(nil) == nil
    end
  end

  describe "check_for_update/1" do
    test "detects available update and extracts matching platform asset" do
      payload =
        Jason.encode!(%{
          "tag_name" => "v0.1.10",
          "name" => "Strata v0.1.10",
          "html_url" => "https://github.com/quaywin/strata/releases/tag/v0.1.10",
          "published_at" => "2026-11-27T10:00:00Z",
          "body" => "## Changes\n- Added self-updater",
          "assets" => [
            %{
              "name" => "strata_macos_aarch64",
              "browser_download_url" => "https://example.test/strata_macos_aarch64",
              "size" => 1234,
              "digest" => "sha256:" <> String.duplicate("a", 64)
            },
            %{
              "name" => "strata_linux_x86_64",
              "browser_download_url" => "https://example.test/strata_linux_x86_64",
              "size" => 5678
            }
          ]
        })

      http_get = fn url, _headers ->
        assert url == "https://api.github.com/repos/quaywin/strata/releases/latest"
        {:ok, 200, [], payload}
      end

      assert {:ok, info} =
               Updater.check_for_update(
                 current_version: "0.1.9",
                 target: :macos_aarch64,
                 http_get: http_get
               )

      assert info.status == :update_available
      assert info.current_version == "0.1.9"
      assert info.latest_version == "0.1.10"
      assert info.tag_name == "v0.1.10"
      assert info.download_url == "https://example.test/strata_macos_aarch64"
      assert info.asset_size == 1234
      assert info.asset_digest == "sha256:" <> String.duplicate("a", 64)
    end

    test "reports up_to_date when zero-padded tag matches current version" do
      payload = Jason.encode!(%{"tag_name" => "v0.1.09", "assets" => []})

      assert {:ok, info} =
               Updater.check_for_update(
                 current_version: "0.1.9",
                 target: :macos_aarch64,
                 http_get: fn _, _ -> {:ok, 200, [], payload} end
               )

      assert info.status == :up_to_date
    end

    test "handles specific tag lookup, rate limit, 404, and network errors" do
      assert {:error, msg_404} =
               Updater.check_for_update(
                 version: "0.9.9",
                 http_get: fn url, _ ->
                   assert String.ends_with?(url, "/releases/tags/v0.9.9")
                   {:ok, 404, [], ~s({"message":"Not Found"})}
                 end
               )

      assert msg_404 =~ "v0.9.9"

      assert {:error, msg_rl} =
               Updater.check_for_update(
                 http_get: fn _, _ ->
                   {:ok, 403, [{"x-ratelimit-remaining", "0"}], ~s({"message":"rate limit"})}
                 end
               )

      assert msg_rl =~ "rate limit"

      assert {:error, msg_net} =
               Updater.check_for_update(http_get: fn _, _ -> {:error, :timeout} end)

      assert msg_net =~ "timed out"
    end
  end

  describe "apply_update/2" do
    setup do
      tmp_dir =
        Path.join(System.tmp_dir!(), "strata_updater_test_#{:erlang.unique_integer([:positive])}")

      File.mkdir_p!(tmp_dir)
      on_exit(fn -> File.rm_rf!(tmp_dir) end)
      {:ok, tmp_dir: tmp_dir}
    end

    test "downloads, verifies SHA-256 and executable header, chmods, and atomically replaces binary",
         %{
           tmp_dir: tmp_dir
         } do
      bin_path = Path.join(tmp_dir, "strata")
      File.write!(bin_path, @macho_magic <> "old-binary")

      new_bytes = @macho_magic <> "new-strata-release-binary"
      digest = "sha256:" <> (:crypto.hash(:sha256, new_bytes) |> Base.encode16(case: :lower))

      info = %{
        status: :update_available,
        current_version: "0.1.9",
        latest_version: "0.1.10",
        tag_name: "v0.1.10",
        release_url: "https://github.com/quaywin/strata/releases/tag/v0.1.10",
        target: :macos_aarch64,
        asset_name: "strata_macos_aarch64",
        download_url: "https://example.test/strata_macos_aarch64",
        asset_size: byte_size(new_bytes),
        asset_digest: digest
      }

      http_download = fn _url, dest, _headers ->
        File.write!(dest, new_bytes)
        :ok
      end

      assert {:ok, res} =
               Updater.apply_update(info,
                 binary_path: bin_path,
                 target: :macos_aarch64,
                 pre_extract: false,
                 http_download: http_download
               )

      assert res.version == "0.1.10"
      assert res.binary_path == bin_path
      assert File.read!(bin_path) == new_bytes
      assert {:ok, %{mode: mode}} = File.stat(bin_path)
      assert Bitwise.band(mode, 0o111) != 0
    end

    test "rejects corrupt header or SHA-256 mismatch without overwriting existing binary", %{
      tmp_dir: tmp_dir
    } do
      bin_path = Path.join(tmp_dir, "strata")
      File.write!(bin_path, @elf_magic <> "original")

      bad_info = %{
        status: :update_available,
        current_version: "0.1.9",
        latest_version: "0.1.10",
        tag_name: "v0.1.10",
        release_url: "",
        target: :linux_x86_64,
        asset_name: "strata_linux_x86_64",
        download_url: "https://example.test/strata_linux_x86_64",
        asset_size: nil,
        asset_digest: nil
      }

      assert {:error, header_err} =
               Updater.apply_update(bad_info,
                 binary_path: bin_path,
                 target: :linux_x86_64,
                 pre_extract: false,
                 http_download: fn _, dest, _ ->
                   File.write!(dest, "<html>Not Found</html>")
                   :ok
                 end
               )

      assert header_err =~ "not a valid linux_x86_64 executable"
      assert File.read!(bin_path) == @elf_magic <> "original"

      digest_info = %{
        bad_info
        | asset_digest: "sha256:" <> String.duplicate("0", 64)
      }

      assert {:error, digest_err} =
               Updater.apply_update(digest_info,
                 binary_path: bin_path,
                 target: :linux_x86_64,
                 pre_extract: false,
                 http_download: fn _, dest, _ ->
                   File.write!(dest, @elf_magic <> "tampered")
                   :ok
                 end
               )

      assert digest_err =~ "SHA-256 verification failed"
      assert File.read!(bin_path) == @elf_magic <> "original"
    end

    test "refuses in-place replacement in source mode without explicit binary_path" do
      info = %{
        status: :update_available,
        current_version: "0.1.9",
        latest_version: "0.1.10",
        tag_name: "v0.1.10",
        release_url: "",
        target: :macos_aarch64,
        asset_name: "strata_macos_aarch64",
        download_url: "https://example.test/strata_macos_aarch64",
        asset_size: 100,
        asset_digest: nil
      }

      assert {:error, msg} = Updater.apply_update(info, burrito?: false)
      assert msg =~ "source"
    end
  end
end
