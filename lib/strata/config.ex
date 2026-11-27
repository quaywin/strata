defmodule Strata.Config do
  @moduledoc """
  Manages configuration file paths using binary ETS at ~/.strata/.
  Mirrors Caudata's storage design and works in both Mix and Burrito releases.
  """

  @env Application.compile_env(:strata, :env, :prod)
  @default_dir "~/.strata"
  @default_file "config.db"
  @default_ssh_file "ssh_profiles.db"
  @default_ai_file "ai_settings.json"
  @default_workspace_file "workspace.json"

  @doc """
  Returns the path to the main configuration database file.
  """
  def config_path do
    if @env == :test do
      Path.join(System.tmp_dir!(), "strata_test_config.db")
    else
      System.get_env("STRATA_CONFIG_PATH") ||
        Path.join(Path.expand(@default_dir), @default_file)
    end
  end

  @doc """
  Returns the path to the persisted SSH profile database file.
  """
  def ssh_config_path do
    if @env == :test do
      Path.join(System.tmp_dir!(), "strata_test_ssh_profiles.db")
    else
      System.get_env("STRATA_SSH_DB_PATH") ||
        Path.join(Path.expand(@default_dir), @default_ssh_file)
    end
  end

  @doc """
  Returns the path to the JSON fallback configuration file.
  """
  def json_config_path do
    if @env == :test do
      Path.join(System.tmp_dir!(), "strata_test_profiles.json")
    else
      Path.expand("~/.config/strata/profiles.json")
    end
  end

  @doc """
  Returns the path to the persisted AI assistant settings JSON file.
  """
  def ai_settings_path do
    if @env == :test do
      Path.join(System.tmp_dir!(), "strata_test_ai_settings.json")
    else
      System.get_env("STRATA_AI_SETTINGS_PATH") ||
        Path.join(Path.expand(@default_dir), @default_ai_file)
    end
  end

  @doc """
  Returns the path to the persisted SQL query tabs & AI workspace JSON file.
  """
  def workspace_path do
    if @env == :test do
      Path.join(System.tmp_dir!(), "strata_test_workspace.json")
    else
      System.get_env("STRATA_WORKSPACE_PATH") ||
        Path.join(Path.expand(@default_dir), @default_workspace_file)
    end
  end
end
