defmodule Strata.UI.Components.ActionsModal do
  @moduledoc """
  Unified Table Actions popup (`[?] Actions`) exposing extended Table View
  commands so the bottom status/menu bar stays minimal and clean.
  """

  alias Strata.UI.Components.DataGrid

  defstruct items: [], selected_index: 0

  @type action_item :: %{id: atom(), label: String.t(), shortcut: String.t()}
  @type t :: %__MODULE__{
          items: [action_item()],
          selected_index: non_neg_integer()
        }

  @doc """
  Builds the contextual action list for the given `DataGrid` and source context.
  """
  @spec new(DataGrid.t(), atom()) :: t()
  def new(%DataGrid{} = grid \\ DataGrid.new(), data_source \\ :table_view) do
    dirty = DataGrid.dirty_count(grid)
    in_data? = grid.view_mode == :data
    items = []

    items =
      if dirty > 0 do
        items ++
          [
            %{id: :commit_changes, label: "Commit #{dirty} Staged Change(s)", shortcut: "Ctrl+S"},
            %{id: :revert_changes, label: "Revert All Staged Changes", shortcut: "Ctrl+Z"}
          ]
      else
        items
      end

    items =
      if in_data? and grid.columns != [] do
        items ++
          [
            %{id: :edit_cell, label: "Edit Selected Cell", shortcut: "e"},
            %{id: :insert_row, label: "Insert Blank Row", shortcut: "i"},
            %{id: :delete_row, label: "Delete / Unmark Selected Row", shortcut: "d"}
          ]
      else
        items
      end

    items =
      items ++
        [
          %{id: :sort_col, label: "Sort Active Column (ASC / DESC)", shortcut: "o"}
        ]

    items =
      if grid.sort_by != nil do
        items ++ [%{id: :clear_sort, label: "Clear Active Sort", shortcut: "-"}]
      else
        items
      end

    items =
      if data_source == :table_view do
        target_label =
          if grid.view_mode == :data,
            do: "Switch to Table Structure View",
            else: "Switch to Table Data View"

        items ++ [%{id: :toggle_structure, label: target_label, shortcut: "s / F3"}]
      else
        items
      end

    items =
      items ++
        [
          %{id: :filter_table, label: "Smart Filter Bar", shortcut: "f / /"},
          %{id: :filter_by_cell, label: "Filter by Selected Cell Value", shortcut: "Shift+F"},
          %{id: :clear_filter, label: "Clear Active Filter", shortcut: "Ctrl+L"},
          %{id: :toggle_inspector, label: "Toggle Right Inspector Drawer", shortcut: "I / F4"},
          %{id: :export_data, label: "Export Data (CSV / JSON / SQL)", shortcut: "E"},
          %{id: :copy_cell, label: "Copy Selected Cell", shortcut: "c"},
          %{id: :copy_row, label: "Copy Entire Row (TSV)", shortcut: "Y"},
          %{id: :next_page, label: "Next Page", shortcut: "n"},
          %{id: :prev_page, label: "Previous Page", shortcut: "p"},
          %{id: :refresh, label: "Refresh Table / Query", shortcut: "r"}
        ]

    %__MODULE__{items: items, selected_index: 0}
  end

  @doc """
  Handles key navigation and selection inside the Actions popup.
  Returns `{:execute, action_id, modal}`, `{:cancel, modal}`, or `modal`.
  """
  @spec handle_key(t(), term()) :: t() | {:execute, atom(), t()} | {:cancel, t()}
  def handle_key(%__MODULE__{items: items} = modal, key) do
    max_idx = max(0, length(items) - 1)

    case key do
      k when k in [:esc, "?", "q", "Q"] ->
        {:cancel, modal}

      k when k in [:up, "k", "K"] ->
        next = if modal.selected_index <= 0, do: max_idx, else: modal.selected_index - 1
        %{modal | selected_index: next}

      k when k in [:down, "j", "J"] ->
        next = if modal.selected_index >= max_idx, do: 0, else: modal.selected_index + 1
        %{modal | selected_index: next}

      :home ->
        %{modal | selected_index: 0}

      :end ->
        %{modal | selected_index: max_idx}

      k when k in [:enter, :space] ->
        case Enum.at(items, modal.selected_index) do
          %{id: id} -> {:execute, id, modal}
          nil -> {:cancel, modal}
        end

      _ ->
        modal
    end
  end
end
