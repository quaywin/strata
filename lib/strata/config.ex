defmodule Strata.Config do
  @moduledoc """
  Manages loading, parsing, and persisting settings using binary ETS at ~/.strata/config.db.
  Mirrors Caudata's storage design. Isolated in test environment.
  """

  @default_dir "~/.strata"
  @default_file "config.db"

  @doc """
  Returns the path to the configuration file.
  Can be overridden by STRATA_CONFIG_PATH environment variable.
  Isolated to temp file in test environment.
  """
  def config_path do
    if Mix.env() == :test do
      Path.join(System.tmp_dir!(), "strata_test_config.db")
    else
      System.get_env("STRATA_CONFIG_PATH") ||
        Path.join(Path.expand(@default_dir), @default_file)
    end
  end
end
