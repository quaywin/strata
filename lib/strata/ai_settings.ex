defmodule Strata.AISettings do
  @moduledoc """
  Configuration struct for local AI CLI integration (`claude`, `codex`, `agy`).
  """

  @providers [:claude, :codex, :agy]
  @context_scopes [:focused_and_related, :focused_only]

  defstruct provider: :claude,
            model: "",
            context_scope: :focused_and_related,
            keep_conversation: true

  @type provider :: :claude | :codex | :agy
  @type context_scope :: :focused_and_related | :focused_only

  @type t :: %__MODULE__{
          provider: provider(),
          model: String.t(),
          context_scope: context_scope(),
          keep_conversation: boolean()
        }

  @doc """
  Returns all supported AI CLI providers in priority order.
  """
  @spec providers() :: [provider()]
  def providers, do: @providers

  @doc """
  Returns all supported schema context scopes.
  """
  @spec context_scopes() :: [context_scope()]
  def context_scopes, do: @context_scopes

  @doc """
  Creates a default `AISettings` struct, preferring the first installed CLI found in PATH.
  """
  @spec default() :: t()
  def default do
    %__MODULE__{provider: detect_default_provider()}
  end

  @doc """
  Returns the first installed provider executable in PATH, falling back to `:claude`.
  """
  @spec detect_default_provider() :: provider()
  def detect_default_provider do
    Enum.find(@providers, :claude, &cli_available?/1)
  end

  @doc """
  Returns the executable name for the given provider atom.
  """
  @spec cli_command(provider()) :: String.t()
  def cli_command(:claude), do: "claude"
  def cli_command(:codex), do: "codex"
  def cli_command(:agy), do: "agy"

  @doc """
  Resolves the executable path in `PATH` for the given provider, or `nil`.
  """
  @spec find_executable(provider()) :: String.t() | nil
  def find_executable(provider) when provider in @providers do
    System.find_executable(cli_command(provider))
  end

  def find_executable(_), do: nil

  @doc """
  Returns true when the provider CLI binary is available in `PATH`.
  """
  @spec cli_available?(provider()) :: boolean()
  def cli_available?(provider), do: is_binary(find_executable(provider))

  @doc """
  Human-readable label for a provider including installation status.
  """
  @spec provider_status_label(provider()) :: String.t()
  def provider_status_label(provider) when provider in @providers do
    status = if cli_available?(provider), do: "Installed ✓", else: "Not found ✗"
    "#{cli_command(provider)} (#{status})"
  end

  @doc """
  Human-readable label for a schema context scope.
  """
  @spec context_scope_label(context_scope()) :: String.t()
  def context_scope_label(:focused_and_related), do: "Focused + Related/Cached Schema"
  def context_scope_label(:focused_only), do: "Focused Table Only"

  @doc """
  Serializes `AISettings` into a JSON-compatible map.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = s) do
    %{
      "provider" => Atom.to_string(normalize_provider(s.provider)),
      "model" => to_string(s.model || ""),
      "context_scope" => Atom.to_string(normalize_scope(s.context_scope)),
      "keep_conversation" => s.keep_conversation != false
    }
  end

  @doc """
  Deserializes a JSON map into an `AISettings` struct with safe defaults.
  """
  @spec from_map(map()) :: t()
  def from_map(map) when is_map(map) do
    %__MODULE__{
      provider: normalize_provider(Map.get(map, "provider")),
      model: map |> Map.get("model", "") |> to_string() |> String.trim(),
      context_scope: normalize_scope(Map.get(map, "context_scope")),
      keep_conversation: Map.get(map, "keep_conversation", true) != false
    }
  end

  def from_map(_), do: default()

  @doc false
  def normalize_provider(p) when p in @providers, do: p
  def normalize_provider("claude"), do: :claude
  def normalize_provider("codex"), do: :codex
  def normalize_provider("agy"), do: :agy
  def normalize_provider(_), do: detect_default_provider()

  @doc false
  def normalize_scope(s) when s in @context_scopes, do: s
  def normalize_scope("focused_only"), do: :focused_only
  def normalize_scope("focused_and_related"), do: :focused_and_related
  def normalize_scope(_), do: :focused_and_related
end
