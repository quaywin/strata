defmodule Strata.CLITest do
  use ExUnit.Case, async: true

  test "parse_args recognizes version, help, update, empty, and invalid args" do
    assert Strata.CLI.parse_args([]) == :continue
    assert Strata.CLI.parse_args(["--version"]) == :version
    assert Strata.CLI.parse_args(["-v"]) == :version
    assert Strata.CLI.parse_args(["--help"]) == :help
    assert Strata.CLI.parse_args(["-h"]) == :help
    assert Strata.CLI.parse_args(["update"]) == {:update, [check_only: false]}
    assert Strata.CLI.parse_args(["--update"]) == {:update, [check_only: false]}
    assert Strata.CLI.parse_args(["update", "--check"]) == {:update, [check_only: true]}
    assert Strata.CLI.parse_args(["--check-update"]) == {:update, [check_only: true]}

    assert Strata.CLI.parse_args(["update", "--version", "v0.1.10"]) ==
             {:update, [check_only: false, version: "v0.1.10"]}

    assert Strata.CLI.parse_args(["--unknown"]) == {:error, ["--unknown"]}
  end

  test "run_update reports check-only update availability" do
    {:ok, io} = StringIO.open("")

    payload =
      Jason.encode!(%{
        "tag_name" => "v99.0.0",
        "html_url" => "https://github.com/quaywin/strata/releases/tag/v99.0.0",
        "assets" => []
      })

    assert :ok ==
             Strata.CLI.run_update(
               check_only: true,
               io: io,
               http_get: fn _url, _headers -> {:ok, 200, [], payload} end
             )

    {_in, out} = StringIO.contents(io)
    assert out =~ "99.0.0"
  end

  test "version returns application version string" do
    assert is_binary(Strata.CLI.version())
    assert Strata.CLI.version() != ""
  end

  test "tui_start_opts enables terminal, mouse capture, and keyboard enhancement" do
    opts = Strata.CLI.tui_start_opts()
    assert Keyword.get(opts, :name) == Strata.UI.App
    assert Keyword.get(opts, :terminal) == true
    assert Keyword.get(opts, :mouse_capture) == true
    assert Keyword.get(opts, :keyboard_enhancement) == true
  end
end
