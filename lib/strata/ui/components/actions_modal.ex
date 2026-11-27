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
  Builds the contextual action list for the given `DataGrid`, source view, and focus pane.
  """
  @spec new(DataGrid.t(), atom(), keyword()) :: t()
  def new(%DataGrid{} = grid \\ DataGrid.new(), data_source \\ :table_view, opts \\ []) do
    focus = Keyword.get(opts, :focus, :datagrid)
    inspector_open? = Keyword.get(opts, :inspector_open, false)
    update_info = Keyword.get(opts, :update_info)
    update_item = update_action_item(update_info)

    items =
      case focus do
        :sidebar ->
          sidebar_items() ++ [update_item] ++ navigation_items(data_source)

        :editor ->
          editor_result_items =
            if grid.columns != [],
              do: datagrid_items(grid, data_source, inspector_open?),
              else: []

          editor_items() ++ [update_item] ++ navigation_items(data_source) ++ editor_result_items

        _ ->
          datagrid_items(grid, data_source, inspector_open?) ++
            [
              %{id: :ai_settings, label: "AI Assistant Settings", shortcut: "Actions"},
              update_item,
              %{id: :sidebar_ssh, label: "SSH Tunnel Profiles", shortcut: "Sidebar S"}
            ] ++
            navigation_items(data_source)
      end

    %__MODULE__{items: items, selected_index: 0}
  end

  defp update_action_item(%{status: :update_available, latest_version: ver})
       when is_binary(ver) do
    %{id: :check_updates, label: "Check for Updates (🆕 v#{ver})", shortcut: "Actions"}
  end

  defp update_action_item(_info) do
    %{
      id: :check_updates,
      label: "Check for Updates (v#{Strata.CLI.version()})",
      shortcut: "Actions"
    }
  end

  defp sidebar_items do
    [
      %{id: :sidebar_add_conn, label: "Add Database Connection", shortcut: "a"},
      %{id: :sidebar_edit_conn, label: "Edit Selected Connection", shortcut: "e"},
      %{id: :sidebar_delete_conn, label: "Delete Selected Connection", shortcut: "d"},
      %{id: :sidebar_ssh, label: "SSH Tunnel Profiles", shortcut: "s / S"},
      %{id: :sidebar_refresh, label: "Refresh Connection Schema", shortcut: "r / F5"},
      %{id: :sidebar_filter, label: "Filter Sidebar Tree", shortcut: "/"},
      %{id: :sidebar_expand_all, label: "Expand All Nodes", shortcut: "o"},
      %{id: :sidebar_collapse_all, label: "Collapse All Nodes", shortcut: "c"},
      %{id: :ai_settings, label: "AI Assistant Settings", shortcut: "Actions"}
    ]
  end

  defp editor_items do
    [
      %{id: :run_query, label: "Run SQL Query", shortcut: "Ctrl+Enter"},
      %{id: :ai_sql_assistant, label: "AI SQL Assistant", shortcut: "Ctrl+O / F6"},
      %{id: :trigger_autocomplete, label: "Trigger SQL Autocomplete", shortcut: "Ctrl+Space"},
      %{id: :clear_editor, label: "Clear SQL Editor", shortcut: "Ctrl+K"},
      %{id: :focus_grid, label: "Focus Result Grid", shortcut: "Esc"},
      %{id: :ai_settings, label: "AI Assistant Settings", shortcut: "Actions"}
    ]
  end

  defp datagrid_items(grid, data_source, inspector_open?) do
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
        select_label =
          if grid.mode == :selecting,
            do: "Exit Select Mode (Browse)",
            else: "Enter Select Mode (Cells)"

        items ++
          [
            %{id: :edit_cell, label: "Edit Selected Cell", shortcut: "e"},
            %{id: :insert_row, label: "Insert Blank Row", shortcut: "i"},
            %{id: :delete_row, label: "Delete / Unmark Selected Row", shortcut: "d"},
            %{id: :toggle_select_mode, label: select_label, shortcut: "v"}
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

        items ++
          [
            %{id: :toggle_structure, label: target_label, shortcut: "s / F3"},
            %{id: :open_in_sql, label: "Open Table Query in SQL Editor", shortcut: "Ctrl+G"}
          ]
      else
        items
      end

    inspector_items =
      if inspector_open? do
        [
          %{id: :toggle_inspector, label: "Toggle Right Inspector Drawer", shortcut: "I / F4"},
          %{
            id: :cycle_inspector_format,
            label: "Cycle Inspector Format (Auto/Text/Raw)",
            shortcut: "m"
          }
        ]
      else
        [%{id: :toggle_inspector, label: "Toggle Right Inspector Drawer", shortcut: "I / F4"}]
      end

    items ++
      [
        %{id: :filter_table, label: "Filter & Sort Bar", shortcut: "f / /"},
        %{id: :filter_by_cell, label: "Filter by Selected Cell Value", shortcut: "Shift+F"},
        %{id: :clear_filter, label: "Clear Active Filter", shortcut: "Ctrl+L"}
      ] ++
      inspector_items ++
      [
        %{id: :export_data, label: "Export Data (CSV / JSON / SQL)", shortcut: "E / Ctrl+E"},
        %{id: :copy_cell, label: "Copy Selected Cell", shortcut: "c"},
        %{id: :copy_row, label: "Copy Entire Row (TSV)", shortcut: "Y"},
        %{id: :refresh, label: "Refresh Table / Query", shortcut: "r"}
      ]
  end

  defp navigation_items(data_source) do
    view_item =
      if data_source == :table_view do
        %{id: :switch_query_view, label: "Switch to SQL Query View", shortcut: "Ctrl+2 / F2"}
      else
        %{id: :switch_table_view, label: "Switch to Table Data View", shortcut: "Ctrl+1 / F1"}
      end

    [
      view_item,
      %{id: :new_sql_tab, label: "New SQL Query Tab", shortcut: "Ctrl+T"},
      %{id: :close_tab, label: "Close Current Tab", shortcut: "Ctrl+W"},
      %{id: :next_tab, label: "Switch Next Tab", shortcut: "Ctrl+→"}
    ]
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
