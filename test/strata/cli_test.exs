defmodule Strata.CLITest do
  use ExUnit.Case, async: true

  test "parse_args recognizes version, help, empty, and invalid args" do
    assert Strata.CLI.parse_args([]) == :continue
    assert Strata.CLI.parse_args(["--version"]) == :version
    assert Strata.CLI.parse_args(["-v"]) == :version
    assert Strata.CLI.parse_args(["--help"]) == :help
    assert Strata.CLI.parse_args(["-h"]) == :help
    assert Strata.CLI.parse_args(["--unknown"]) == {:error, ["--unknown"]}
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
