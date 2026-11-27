defmodule Strata.UI.Components.UpdateModal do
  @moduledoc """
  Modal component for checking, viewing, and applying Strata application updates.
  """

  alias Strata.Updater

  defstruct current_version: "0.1.0",
            latest_version: nil,
            tag_name: nil,
            release_url: nil,
            release_notes: nil,
            published_at: nil,
            target: nil,
            install_mode: :source,
            binary_path: nil,
            update_info: nil,
            focused_field: :check_button,
            status: :idle,
            status_message: nil

  @type status ::
          :idle
          | :checking
          | :up_to_date
          | :update_available
          | :ahead
          | :updating
          | :updated
          | :error

  @type t :: %__MODULE__{
          current_version: String.t(),
          latest_version: String.t() | nil,
          tag_name: String.t() | nil,
          release_url: String.t() | nil,
          release_notes: String.t() | nil,
          published_at: String.t() | nil,
          target: Updater.target() | nil,
          install_mode: :burrito | :source,
          binary_path: String.t() | nil,
          update_info: Updater.release_info() | nil,
          focused_field: :check_button | :update_button | :close_button,
          status: status(),
          status_message: String.t() | nil
        }

  @doc """
  Initializes an `UpdateModal` with current version, install target info, and optional cached `update_info`.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    current = Keyword.get_lazy(opts, :current_version, fn -> Strata.CLI.version() end)
    install = Keyword.get_lazy(opts, :install_target, fn -> Updater.install_target() end)
    cached_info = Keyword.get(opts, :update_info)

    base = %__MODULE__{
      current_version: Updater.normalize_semver(current) || current,
      target: install.target,
      install_mode: install.mode,
      binary_path: install.binary_path,
      status_message: "Press [Check for Updates] to check GitHub Releases."
    }

    base =
      if is_map(cached_info) do
        apply_check_result(base, {:ok, cached_info})
      else
        base
      end

    struct(base, Keyword.drop(opts, [:current_version, :install_target, :update_info]))
  end

  @doc """
  Returns the ordered interactive button fields for keyboard navigation.
  """
  @spec visible_buttons(t()) :: [atom()]
  def visible_buttons(%__MODULE__{status: :update_available, update_info: %{} = _info}) do
    [:check_button, :update_button, :close_button]
  end

  def visible_buttons(_modal) do
    [:check_button, :close_button]
  end

  @doc """
  Applies the result of `Strata.Updater.check_for_update/1` to the modal state.
  """
  @spec apply_check_result(t(), {:ok, Updater.release_info()} | {:error, String.t()}) :: t()
  def apply_check_result(%__MODULE__{} = modal, {:ok, info}) do
    {status, message, focus} =
      case info.status do
        :update_available ->
          msg =
            cond do
              is_nil(info.download_url) ->
                "🆕 v#{info.latest_version} available, but no prebuilt #{info.target} binary exists."

              modal.install_mode == :source ->
                "🆕 v#{info.latest_version} available (source mode — run `git pull` or `install.sh`)."

              true ->
                "🆕 Update available: v#{modal.current_version} → v#{info.latest_version}"
            end

          {:update_available, msg, :update_button}

        :up_to_date ->
          {:up_to_date, "✅ Strata is up to date (v#{info.latest_version}).", :close_button}

        :ahead ->
          {:ahead,
           "✅ Current build (v#{modal.current_version}) is ahead of v#{info.latest_version}.",
           :close_button}
      end

    %{
      modal
      | latest_version: info.latest_version,
        tag_name: info.tag_name,
        release_url: info.release_url,
        release_notes: summarize_notes(info.release_notes),
        published_at: info.published_at,
        update_info: info,
        status: status,
        status_message: message,
        focused_field: focus
    }
  end

  def apply_check_result(%__MODULE__{} = modal, {:error, reason}) do
    msg = Strata.Formatter.format_error(reason)
    %{modal | status: :error, status_message: "❌ #{msg}", focused_field: :check_button}
  end

  @doc """
  Applies the result of `Strata.Updater.apply_update/2` to the modal state.
  """
  @spec apply_install_result(t(), {:ok, map()} | {:error, String.t()}) :: t()
  def apply_install_result(%__MODULE__{} = modal, {:ok, result}) do
    %{
      modal
      | status: :updated,
        latest_version: result.version,
        binary_path: result.binary_path,
        status_message: "✅ Updated to v#{result.version}! Quit [q] and restart strata.",
        focused_field: :close_button
    }
  end

  def apply_install_result(%__MODULE__{} = modal, {:error, reason}) do
    msg = Strata.Formatter.format_error(reason)

    %{
      modal
      | status: :error,
        status_message: "❌ Update failed: #{msg}",
        focused_field: :close_button
    }
  end

  @doc """
  Handles keyboard events inside `UpdateModal`.
  Returns `{:check, modal}`, `{:install, modal}`, `{:cancel, modal}`, or updated `modal`.
  """
  @spec handle_key(t(), term()) ::
          t() | {:check, t()} | {:install, t()} | {:cancel, t()}
  def handle_key(%__MODULE__{} = modal, key) when key in [:esc, "q", "Q"] do
    {:cancel, modal}
  end

  def handle_key(%__MODULE__{} = modal, key) when key in [:tab, :down, :right] do
    %{modal | focused_field: next_button(modal, 1)}
  end

  def handle_key(%__MODULE__{} = modal, key) when key in [:shift_tab, :up, :left] do
    %{modal | focused_field: next_button(modal, -1)}
  end

  def handle_key(%__MODULE__{focused_field: :check_button} = modal, key)
      when key in [:enter, :space] do
    if modal.status in [:checking, :updating], do: modal, else: {:check, modal}
  end

  def handle_key(%__MODULE__{focused_field: :update_button} = modal, key)
      when key in [:enter, :space] do
    if modal.status in [:checking, :updating], do: modal, else: {:install, modal}
  end

  def handle_key(%__MODULE__{focused_field: :close_button} = modal, key)
      when key in [:enter, :space] do
    {:cancel, modal}
  end

  def handle_key(modal, _key), do: modal

  @doc """
  Returns the rendered field list (info rows followed by interactive buttons).
  """
  @spec rendered_fields(t()) :: [map()]
  def rendered_fields(%__MODULE__{} = modal) do
    latest_display =
      cond do
        modal.status == :checking -> "Checking..."
        is_binary(modal.latest_version) -> "v#{modal.latest_version}"
        true -> "(Not checked yet)"
      end

    target_display =
      if modal.target do
        "#{modal.target}"
      else
        "Unknown"
      end

    install_display =
      case {modal.install_mode, modal.binary_path} do
        {:burrito, path} when is_binary(path) -> "Standalone (#{path})"
        {:burrito, _} -> "Standalone Binary"
        {:source, _} -> "Source (Mix)"
      end

    notes_display =
      if is_binary(modal.release_notes) and modal.release_notes != "" do
        modal.release_notes
      else
        "—"
      end

    info_fields = [
      %{
        label: "Current Version",
        key: :current_version,
        value: "v#{modal.current_version}",
        type: :info
      },
      %{label: "Latest Version", key: :latest_version, value: latest_display, type: :info},
      %{label: "Target Platform", key: :target, value: target_display, type: :info},
      %{label: "Install Mode", key: :install_mode, value: install_display, type: :info},
      %{label: "Release Notes", key: :release_notes, value: notes_display, type: :info}
    ]

    button_defs = %{
      check_button: %{label: "[🔄 Check for Updates]", key: :check_button, type: :button},
      update_button: %{label: "[⬇ Install Update]", key: :update_button, type: :button},
      close_button: %{label: "[ Close (Esc) ]", key: :close_button, type: :button}
    }

    buttons = Enum.map(visible_buttons(modal), &Map.fetch!(button_defs, &1))
    info_fields ++ buttons
  end

  @doc """
  Renders structured map representation of the modal for `Renderer`.
  """
  @spec render(t(), map()) :: map()
  def render(%__MODULE__{} = modal, area) do
    %{
      title: "APP UPDATE",
      area: area,
      focused_field: modal.focused_field,
      fields: rendered_fields(modal),
      status: modal.status,
      status_message: modal.status_message
    }
  end

  defp next_button(modal, delta) do
    buttons = visible_buttons(modal)
    idx = Enum.find_index(buttons, &(&1 == modal.focused_field)) || 0
    cnt = length(buttons)
    Enum.at(buttons, rem(idx + delta + cnt, cnt))
  end

  defp summarize_notes(nil), do: nil

  defp summarize_notes(notes) when is_binary(notes) do
    first_line =
      notes
      |> String.split(~r/\r?\n/)
      |> Enum.map(&String.trim/1)
      |> Enum.find(&(&1 != "" and not String.starts_with?(&1, "#")))

    case first_line do
      nil -> nil
      line -> String.slice(line, 0, 50)
    end
  end
end
