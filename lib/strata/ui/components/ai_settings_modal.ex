defmodule Strata.UI.Components.AISettingsModal do
  @moduledoc """
  Modal form component for configuring local AI CLI integration (`claude`, `codex`, `agy`),
  optional model override, schema context scope, conversation memory, and `[⚡ Test AI CLI]`.
  """

  alias Strata.AISettings

  @fields [
    :provider,
    :model,
    :context_scope,
    :keep_conversation,
    :test_button,
    :save_button,
    :cancel_button
  ]

  defstruct provider: :claude,
            model: "",
            context_scope: :focused_and_related,
            keep_conversation: true,
            focused_field: :provider,
            status: :idle,
            status_message: nil

  @type t :: %__MODULE__{
          provider: AISettings.provider(),
          model: String.t(),
          context_scope: AISettings.context_scope(),
          keep_conversation: boolean(),
          focused_field: atom(),
          status: :idle | :testing | :ok | :error,
          status_message: String.t() | nil
        }

  @doc """
  Returns the ordered fields for `AISettingsModal`.
  """
  @spec visible_fields() :: [atom()]
  def visible_fields, do: @fields

  @doc """
  Initializes an `AISettingsModal` from `opts[:settings]` or `Strata.AISettingsStore.get/0`.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    settings = Keyword.get_lazy(opts, :settings, fn -> Strata.AISettingsStore.get() end)

    base = %__MODULE__{
      provider: settings.provider,
      model: settings.model || "",
      context_scope: settings.context_scope,
      keep_conversation: settings.keep_conversation != false
    }

    struct(base, Keyword.delete(opts, :settings))
  end

  @doc """
  Converts modal state into a `Strata.AISettings` struct.
  """
  @spec to_settings(t()) :: AISettings.t()
  def to_settings(%__MODULE__{} = modal) do
    %AISettings{
      provider: modal.provider,
      model: String.trim(modal.model || ""),
      context_scope: modal.context_scope,
      keep_conversation: modal.keep_conversation != false
    }
  end

  @doc """
  Handles keyboard navigation, cycling, text entry, save, and cancel.
  """
  def handle_key(%__MODULE__{} = modal, :tab) do
    %{modal | focused_field: next_field(modal.focused_field, 1)}
  end

  def handle_key(%__MODULE__{} = modal, :shift_tab) do
    %{modal | focused_field: next_field(modal.focused_field, -1)}
  end

  def handle_key(%__MODULE__{} = modal, :down), do: handle_key(modal, :tab)
  def handle_key(%__MODULE__{} = modal, :up), do: handle_key(modal, :shift_tab)

  # Provider cycling
  def handle_key(%__MODULE__{focused_field: :provider} = modal, key)
      when key in [:right, :left, :space, :enter] do
    providers = AISettings.providers()
    idx = Enum.find_index(providers, &(&1 == modal.provider)) || 0
    delta = if key == :left, do: -1, else: 1
    next_provider = Enum.at(providers, rem(idx + delta + length(providers), length(providers)))
    %{modal | provider: next_provider, status: :idle, status_message: nil}
  end

  # Context scope cycling
  def handle_key(%__MODULE__{focused_field: :context_scope} = modal, key)
      when key in [:right, :left, :space, :enter] do
    next_scope =
      if modal.context_scope == :focused_and_related,
        do: :focused_only,
        else: :focused_and_related

    %{modal | context_scope: next_scope}
  end

  # Keep conversation toggle
  def handle_key(%__MODULE__{focused_field: :keep_conversation} = modal, key)
      when key in [:right, :left, :space, :enter] do
    %{modal | keep_conversation: not (modal.keep_conversation != false)}
  end

  # Save shortcut & buttons
  def handle_key(%__MODULE__{} = modal, key) when key in [{:ctrl, "s"}, {:ctrl, "S"}] do
    {:save, modal}
  end

  def handle_key(%__MODULE__{focused_field: :save_button} = modal, key)
      when key in [:enter, :space] do
    {:save, modal}
  end

  def handle_key(%__MODULE__{focused_field: :cancel_button} = modal, key)
      when key in [:enter, :space] do
    {:cancel, modal}
  end

  def handle_key(%__MODULE__{focused_field: :test_button} = modal, key)
      when key in [:enter, :space] do
    {:test, modal}
  end

  def handle_key(%__MODULE__{focused_field: :model} = modal, :enter) do
    handle_key(modal, :tab)
  end

  def handle_key(%__MODULE__{focused_field: :model} = modal, :backspace) do
    val = to_string(modal.model || "")
    %{modal | model: String.slice(val, 0, max(0, String.length(val) - 1))}
  end

  def handle_key(%__MODULE__{focused_field: :model} = modal, key)
      when key in [{:ctrl, "u"}, {:ctrl, "k"}] do
    %{modal | model: ""}
  end

  def handle_key(%__MODULE__{focused_field: :model} = modal, key) when is_binary(key) do
    if String.printable?(key) do
      %{modal | model: (modal.model || "") <> key}
    else
      modal
    end
  end

  def handle_key(modal, _key), do: modal

  @doc """
  Renders structured map representation of the modal for `Renderer`.
  """
  @spec render(t(), map()) :: map()
  def render(%__MODULE__{} = modal, area) do
    model_display =
      if String.trim(modal.model || "") == "",
        do: "(CLI default — type to override)",
        else: modal.model

    conv_label = if modal.keep_conversation != false, do: "On (Resume per SQL tab)", else: "Off"

    fields = [
      %{
        label: "AI CLI Provider",
        key: :provider,
        value: AISettings.provider_status_label(modal.provider) <> "  ←/→",
        type: :select
      },
      %{label: "Model Override", key: :model, value: model_display, type: :text},
      %{
        label: "Schema Context",
        key: :context_scope,
        value: AISettings.context_scope_label(modal.context_scope) <> "  ←/→",
        type: :select
      },
      %{
        label: "Tab Conversation",
        key: :keep_conversation,
        value: conv_label <> "  ←/→",
        type: :select
      },
      %{label: "[⚡ Test AI CLI]", key: :test_button, type: :button},
      %{label: "[ Save (Ctrl+S) ]", key: :save_button, type: :button},
      %{label: "[ Cancel (Esc) ]", key: :cancel_button, type: :button}
    ]

    %{
      title: "AI ASSISTANT SETTINGS",
      area: area,
      focused_field: modal.focused_field,
      fields: fields,
      status: modal.status,
      status_message: modal.status_message
    }
  end

  defp next_field(current, delta) do
    idx = Enum.find_index(@fields, &(&1 == current)) || 0
    cnt = length(@fields)
    Enum.at(@fields, rem(idx + delta + cnt, cnt))
  end
end
