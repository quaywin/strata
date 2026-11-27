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
  def determine_context(%{filter_bar_open: true, filter_bar_focused: true}), do: :filter_bar
  def determine_context(%{focus: :sidebar, sidebar_filter_active: true}), do: :sidebar_filter
  def determine_context(%{focus: :sidebar}), do: :sidebar
  def determine_context(%{focus: :editor}), do: :editor
  def determine_context(%{focus: :ai_panel, ai_panel_focus: :history}), do: :ai_panel_history
  def determine_context(%{focus: :ai_panel}), do: :ai_panel_input

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
          {"Tab", "Next"},
          {"←/→", "Option/Btn"},
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
          {"Tab", "Pane"},
          {"Ctrl+T", "New SQL Tab"},
          {"a", "Add Conn"},
          {"r", "Refresh"},
          {"/", "Find"},
          {"?", "Actions"}
        ]

      :editor ->
        [
          {"Ctrl+Enter", "Run"},
          {"Ctrl+Space", "Complete"},
          {"Ctrl+O", "AI"},
          {"Ctrl+T", "New Tab"},
          {"Ctrl+W", "Close"},
          {"Ctrl+←/→", "Tabs"},
          {"Ctrl+P", "Actions"}
        ]

      :ai_panel_input ->
        [
          {"Enter", "Send"},
          {"Shift+Enter", "Newline"},
          {"↑", "History"},
          {"Ctrl+L", "Reset"},
          {"Tab", "Pane"},
          {"Ctrl+O", "Close"},
          {"Esc", "Editor"}
        ]

      :ai_panel_history ->
        [
          {"↑/↓", "Pick Turn"},
          {"Enter", "Apply SQL"},
          {"Ctrl+L", "Reset"},
          {"Tab", "Pane"},
          {"Ctrl+O", "Close"},
          {"Esc", "Input"}
        ]

      :datagrid_editing ->
        [
          {"Enter", "Stage"},
          {"Ctrl+N", "NULL"},
          {"Esc", "Cancel"}
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

          Map.get(app, :filter_dropdown) == :sort ->
            [
              {"↑/↓", "Pick Col"},
              {"Type", "Search"},
              {"Enter", "Sort"},
              {"Esc", "Close"}
            ]

          Map.get(app, :filter_bar_focus_part, :value) in [:column, :op, :sort] ->
            [
              {"↑/↓", "Pick"},
              {"Tab", "Next"},
              {"Ctrl+G", "SQL Tab"},
              {"Ctrl+L", "Reset"}
            ]

          true ->
            [
              {"Enter", "Apply"},
              {"Tab", "Col/Op/Sort"},
              {"Ctrl+G", "SQL Tab"},
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
          {"d", "Del"},
          {"c", "Copy"},
          {"E", "Export"},
          {"?", "Actions"},
          {"Esc", "Back"}
        ]

      :datagrid_browsing ->
        if Map.get(app, :active_view) == :table_view do
          [
            {"Tab", "Pane"},
            {"v", "Select"},
            {"f", "Filter"},
            {"s", "Structure"},
            {"Ctrl+G", "SQL"},
            {"E", "Export"},
            {"?", "Actions"}
          ]
        else
          [
            {"Tab", "Pane"},
            {"v", "Select"},
            {"f", "Filter"},
            {"E", "Export"},
            {"Ctrl+T", "New SQL"},
            {"?", "Actions"}
          ]
        end

      _ ->
        [
          {"Tab", "Pane"},
          {"Ctrl+T", "New SQL Tab"},
          {"Ctrl+W", "Close"},
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
