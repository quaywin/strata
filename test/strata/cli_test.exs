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
end
