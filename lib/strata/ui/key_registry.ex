defmodule Strata.UI.KeyRegistry do
  @moduledoc """
  Single Source of Truth for UI context resolution and the single compact bottom menu,
  mirroring `Caudata.UI.KeyRegistry`.
  """

  @doc """
  Determines the active UI context atom for the given App state.
  """
  @spec determine_context(map()) :: atom()
  def determine_context(%{modals: [_ | _]}), do: :modal
  def determine_context(%{sort_picker_open: true}), do: :sort_picker
  def determine_context(%{filter_bar_open: true, filter_bar_focused: true}), do: :filter_bar
  def determine_context(%{focus: :sidebar, sidebar_filter_active: true}), do: :sidebar_filter
  def determine_context(%{focus: :sidebar}), do: :sidebar
  def determine_context(%{focus: :editor}), do: :editor

  def determine_context(%{focus: :datagrid, datagrid_state: %{editing_cell: {_, _}}}),
    do: :datagrid_editing

  def determine_context(%{focus: :datagrid, datagrid_state: %{} = grid}) do
    dirty =
      map_size(Map.get(grid, :pending_edits, %{})) +
        length(Map.get(grid, :pending_inserts, [])) +
        MapSet.size(Map.get(grid, :pending_deletes, MapSet.new()))

    cond do
      dirty > 0 -> :datagrid_dirty
      Map.get(grid, :mode) == :selecting -> :datagrid_selecting
      true -> :datagrid_browsing
    end
  end

  def determine_context(%{focus: :datagrid}), do: :datagrid_browsing
  def determine_context(_app), do: :default

  @doc """
  Returns at most 5–7 compact `{key, label}` items for the single bottom menu bar.
  """
  @spec get_shortcuts(map()) :: [{String.t(), String.t()}]
  def get_shortcuts(app) do
    case determine_context(app) do
      :modal ->
        [
          {"Tab", "Next Field"},
          {"Enter", "Confirm"},
          {"Esc", "Cancel"}
        ]

      :sidebar_filter ->
        [
          {"↑/↓", "Select"},
          {"Enter", "Open"},
          {"Backspace", "Del"},
          {"Esc", "Clear"}
        ]

      :sidebar ->
        [
          {"Ctrl+1/2", "Table/Query View"},
          {"/", "Find"},
          {"r", "Refresh"},
          {"a", "Add Conn"},
          {"e/d", "Edit/Del"},
          {"S", "SSH"},
          {"?", "Actions"}
        ]

      :editor ->
        [
          {"Ctrl+1/2", "Table/Query View"},
          {"Ctrl+Enter", "Run"},
          {"Ctrl+T", "New Tab"},
          {"Esc", "Grid"},
          {"Tab", "Pane"}
        ]

      :datagrid_editing ->
        [
          {"Enter", "Stage"},
          {"Ctrl+N", "NULL"},
          {"Esc", "Cancel"}
        ]

      :sort_picker ->
        [
          {"↑/↓", "Pick Col"},
          {"Type", "Search"},
          {"Enter", "Sort"},
          {"Esc", "Close"}
        ]

      :filter_bar ->
        cond do
          Map.get(app, :filter_dropdown) == :column ->
            [
              {"↑/↓", "Pick Col"},
              {"Type", "Search"},
              {"Enter", "Select"},
              {"Esc", "Close"}
            ]

          Map.get(app, :filter_dropdown) == :op ->
            [
              {"↑/↓", "Pick Op"},
              {"Enter", "Select"},
              {"Esc", "Close"}
            ]

          Map.get(app, :filter_bar_mode, :builder) == :raw ->
            [
              {"Enter", "Apply"},
              {"Ctrl+V", "Paste"},
              {"Ctrl+U", "Clear"},
              {"Ctrl+R", "Builder"},
              {"Ctrl+L", "Reset"}
            ]

          Map.get(app, :filter_bar_focus_part, :value) in [:column, :op] ->
            [
              {"↑/↓", "Change"},
              {"Tab", "Next"},
              {"Enter", "Apply"},
              {"Ctrl+R", "SQL"},
              {"Ctrl+L", "Reset"}
            ]

          true ->
            [
              {"Enter", "Apply"},
              {"Tab", "Col/Op"},
              {"Ctrl+V", "Paste"},
              {"Ctrl+R", "SQL"},
              {"Ctrl+L", "Reset"}
            ]
        end

      :datagrid_dirty ->
        dirty = dirty_count(Map.get(app, :datagrid_state))

        [
          {"Ctrl+S", "Commit (#{dirty})"},
          {"Ctrl+Z", "Revert"},
          {"e", "Edit"},
          {"i/d", "+/-Row"},
          {"?", "Actions"}
        ]

      :datagrid_selecting ->
        [
          {"Enter", "Inspect"},
          {"e", "Edit"},
          {"i/d", "+/-Row"},
          {"c/Y", "Copy"},
          {"?", "Actions"},
          {"Esc", "Back"}
        ]

      :datagrid_browsing ->
        [
          {"Tab", "Pane"},
          {"v", "Select"},
          {"s", "Structure"},
          {"f", "Filter"},
          {"?", "Actions"},
          {"q", "Quit"}
        ]

      _ ->
        [
          {"Ctrl+1/2", "Table/Query View"},
          {"Tab", "Pane"},
          {"?", "Actions"},
          {"q", "Quit"}
        ]
    end
  end

  defp dirty_count(nil), do: 0

  defp dirty_count(grid) do
    map_size(Map.get(grid, :pending_edits, %{})) +
      length(Map.get(grid, :pending_inserts, [])) +
      MapSet.size(Map.get(grid, :pending_deletes, MapSet.new()))
  end
end
