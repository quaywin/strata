defmodule Strata.UI.Components.ConfirmModal do
  @moduledoc """
  Confirmation modal for destructive or unsaved-changes actions (such as closing a table tab
  or quitting with uncommitted cell edits, inserts, or deletes).
  """

  defstruct kind: :close_dirty_tab,
            tab_id: nil,
            target_id: nil,
            tab_name: nil,
            dirty_count: 0,
            inline_editing?: false,
            can_commit?: true,
            focused_field: :cancel_button,
            status: :idle,
            status_message: nil

  @type kind ::
          :close_dirty_tab
          | :quit_with_dirty_tabs
          | :refresh_dirty_table

  @type t :: %__MODULE__{
          kind: kind(),
          tab_id: String.t() | nil,
          target_id: String.t() | nil,
          tab_name: String.t() | nil,
          dirty_count: non_neg_integer(),
          inline_editing?: boolean(),
          can_commit?: boolean(),
          focused_field: :discard_button | :commit_button | :cancel_button,
          status: :idle | :saving | :error,
          status_message: String.t() | nil
        }

  @doc """
  Initializes a new `ConfirmModal` struct.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    struct(__MODULE__, opts)
  end

  @doc """
  Returns the ordered visible action buttons for the modal.
  """
  @spec visible_buttons(t()) :: [atom()]
  def visible_buttons(%__MODULE__{can_commit?: true}),
    do: [:discard_button, :commit_button, :cancel_button]

  def visible_buttons(%__MODULE__{}),
    do: [:discard_button, :cancel_button]

  @doc """
  Handles keyboard navigation and button activation inside `ConfirmModal`.
  """
  @spec handle_key(t(), term()) ::
          t() | {:discard, t()} | {:commit, t()} | {:cancel, t()}
  def handle_key(%__MODULE__{} = modal, key) when key in [:esc, "n", "N"] do
    {:cancel, modal}
  end

  def handle_key(%__MODULE__{} = modal, key) when key in [:tab, :down, :right] do
    %{modal | focused_field: next_button(modal, 1)}
  end

  def handle_key(%__MODULE__{} = modal, key) when key in [:shift_tab, :up, :left] do
    %{modal | focused_field: next_button(modal, -1)}
  end

  def handle_key(%__MODULE__{can_commit?: true, status: status} = modal, key)
      when key in [{:ctrl, "s"}, {:ctrl, "S"}] and status != :saving do
    {:commit, modal}
  end

  def handle_key(%__MODULE__{focused_field: :discard_button, status: status} = modal, key)
      when key in [:enter, :space] and status != :saving do
    {:discard, modal}
  end

  def handle_key(
        %__MODULE__{focused_field: :commit_button, can_commit?: true, status: status} = modal,
        key
      )
      when key in [:enter, :space] and status != :saving do
    {:commit, modal}
  end

  def handle_key(%__MODULE__{focused_field: :cancel_button} = modal, key)
      when key in [:enter, :space] do
    {:cancel, modal}
  end

  def handle_key(modal, _key), do: modal

  @doc """
  Renders structured map representation of `ConfirmModal` for `Renderer`.
  """
  @spec render(t(), map()) :: map()
  def render(%__MODULE__{} = modal, area) do
    {title, info_fields, discard_label, commit_label, default_msg} =
      case modal.kind do
        :quit_with_dirty_tabs ->
          {
            "UNSAVED TABLE CHANGES",
            [
              %{label: "Tables", key: :tab_info, value: modal.tab_name || "Table", type: :info},
              %{
                label: "Pending Changes",
                key: :dirty_info,
                value: summary_text(modal),
                type: :info
              }
            ],
            if(modal.can_commit?, do: "[ Discard & Quit ]", else: "[ Discard All & Quit ]"),
            "[ Save & Quit ]",
            "You have uncommitted edits. Save changes before leaving?"
          }

        :refresh_dirty_table ->
          {
            "UNSAVED TABLE CHANGES",
            [
              %{label: "Table", key: :tab_info, value: modal.tab_name || "Table", type: :info},
              %{
                label: "Pending Changes",
                key: :dirty_info,
                value: summary_text(modal),
                type: :info
              }
            ],
            "[ Discard & Refresh ]",
            "[ Save & Refresh ]",
            "Refreshing reloads from database and discards unsaved edits."
          }

        _ ->
          {
            "UNSAVED TABLE CHANGES",
            [
              %{label: "Table", key: :tab_info, value: modal.tab_name || "Table", type: :info},
              %{
                label: "Pending Changes",
                key: :dirty_info,
                value: summary_text(modal),
                type: :info
              }
            ],
            "[ Discard & Close ]",
            "[ Save & Close ]",
            "You have uncommitted edits. Save changes before leaving?"
          }
      end

    button_defs = %{
      discard_button: %{label: discard_label, key: :discard_button, type: :button},
      commit_button: %{label: commit_label, key: :commit_button, type: :button},
      cancel_button: %{label: "[ Cancel (Esc) ]", key: :cancel_button, type: :button}
    }

    buttons = Enum.map(visible_buttons(modal), &Map.fetch!(button_defs, &1))

    %{
      title: title,
      area: area,
      focused_field: modal.focused_field,
      fields: info_fields ++ buttons,
      status: modal.status,
      status_message: modal.status_message || default_msg
    }
  end

  defp summary_text(%__MODULE__{dirty_count: count, inline_editing?: true}) when count > 0 do
    "#{count} staged change(s) + active cell edit"
  end

  defp summary_text(%__MODULE__{inline_editing?: true}) do
    "Active cell edit in progress"
  end

  defp summary_text(%__MODULE__{dirty_count: count}) do
    "#{count} uncommitted change(s)"
  end

  defp next_button(modal, delta) do
    buttons = visible_buttons(modal)
    idx = Enum.find_index(buttons, &(&1 == modal.focused_field)) || 0
    cnt = length(buttons)
    Enum.at(buttons, rem(idx + delta + cnt, cnt))
  end
end
