defmodule DBData.UI.App do
  @moduledoc """
  State management for Database TUI interface.
  Manages focus panes, tabbed SQL editor, modal overlays stack, and tree view navigation.
  Integrated with ExRatatui.App behaviour for 60 FPS event-driven TUI.
  """
  use ExRatatui.App

  alias DBData.UI.Components.DataGrid
  alias DBData.UI.Components.Sidebar
  alias DBData.UI.Components.SQLEditor
  alias DBData.UI.Renderer

  @type focus_pane :: :sidebar | :editor | :datagrid
  @type active_view :: :table_view | :query_view

  @type tab :: %{
          id: String.t(),
          name: String.t(),
          content: String.t(),
          cursor: {non_neg_integer(), non_neg_integer()}
        }

  @type t :: %__MODULE__{
          focus: focus_pane(),
          active_view: active_view(),
          selected_table: String.t() | nil,
          tabs: [tab()],
          active_tab_id: String.t() | nil,
          modals: [map()],
          sidebar_nodes: [map()],
          selected_tree_node_id: String.t() | nil,
          datagrid_state: DataGrid.t() | nil,
          mouse_enabled: boolean(),
          window_size: {pos_integer(), pos_integer()},
          status_message: String.t()
        }

  defstruct [
    focus: :sidebar,
    active_view: :table_view,
    selected_table: nil,
    tabs: [],
    active_tab_id: nil,
    modals: [],
    sidebar_nodes: [],
    selected_tree_node_id: nil,
    datagrid_state: nil,
    mouse_enabled: true,
    window_size: {120, 40},
    status_message: "Ready"
  ]

  @panes [:sidebar, :editor, :datagrid]

  # --- ExRatatui.App Callbacks ---

  @impl true
  def mount(opts) do
    {w, h} =
      if Keyword.get(opts, :terminal, false) do
        case ExRatatui.terminal_size() do
          {w, h} -> {w, h}
          _ -> {120, 40}
        end
      else
        {120, 40}
      end

    state = new(window_size: {w, h})
    {:ok, state}
  end

  @impl true
  def handle_event(%ExRatatui.Event.Resize{width: w, height: h}, state) do
    {:noreply, %{state | window_size: {w, h}}}
  end

  def handle_event(%ExRatatui.Event.Key{code: code, modifiers: modifiers}, state) do
    mapped_key = map_ex_ratatui_key(code, modifiers)

    cond do
      mapped_key == :quit and state.focus != :editor and Enum.empty?(state.modals) ->
        {:stop, state}

      true ->
        new_state = handle_key(state, mapped_key)
        {:noreply, new_state}
    end
  end

  def handle_event(%ExRatatui.Event.Mouse{} = mouse, state) do
    col = Map.get(mouse, :column) || Map.get(mouse, :x) || 0
    row = Map.get(mouse, :row) || Map.get(mouse, :y) || 0
    kind = Map.get(mouse, :kind) || Map.get(mouse, :button) || :down
    kind_str = to_string(kind)

    event =
      cond do
        kind_str in ["down", "click"] -> {:click, col, row}
        kind_str in ["scroll_up", "up"] and Map.has_key?(mouse, :kind) and to_string(mouse.kind) == "scroll_up" -> {:scroll, :up, col, row}
        kind_str in ["scroll_down", "down"] and Map.has_key?(mouse, :kind) and to_string(mouse.kind) == "scroll_down" -> {:scroll, :down, col, row}
        kind_str == "scroll_up" -> {:scroll, :up, col, row}
        kind_str == "scroll_down" -> {:scroll, :down, col, row}
        true -> {:mouse_event, kind, col, row}
      end

    new_state = handle_mouse(state, event)
    {:noreply, new_state}
  end

  def handle_event(_event, state), do: {:noreply, state}

  @impl true
  def render(state, frame) do
    state =
      case frame do
        %ExRatatui.Frame{width: w, height: h} when w > 0 and h > 0 ->
          %{state | window_size: {w, h}}

        _ ->
          state
      end

    Renderer.render(state)
  end


  defp map_ex_ratatui_key(code, modifiers) do
    ctrl? = "control" in modifiers or "Ctrl" in modifiers or "ctrl" in modifiers

    cond do
      ctrl? and is_binary(code) and String.length(code) == 1 ->
        {:ctrl, code}

      code in ["up", "Up"] -> :up
      code in ["down", "Down"] -> :down
      code in ["left", "Left"] -> :left
      code in ["right", "Right"] -> :right
      code in ["tab", "Tab"] -> :tab
      code in ["enter", "Enter"] -> :enter
      code in ["esc", "escape", "Esc", "Escape"] -> :esc
      code in ["backspace", "Backspace"] -> :backspace
      code in ["f1", "F1"] -> :f1
      code in ["f2", "F2"] -> :f2
      code in ["f3", "F3"] -> :f3
      code in ["f5", "F5"] -> :f5
      code in ["f6", "F6"] -> :f6
      code in ["q", "Q"] -> :quit
      is_binary(code) and String.length(code) == 1 -> code
      true -> :unknown
    end
  end

  # --- Domain State Logic ---

  @doc """
  Creates a new App state with default or custom options.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    default_tab = %{
      id: "tab_1",
      name: "Query 1",
      content: "",
      cursor: {0, 0}
    }

    default_grid = DataGrid.new([], [])

    nodes = Sidebar.load_nodes()
    first_id = case List.first(nodes) do nil -> nil; n -> n.id end

    base = %__MODULE__{
      active_view: :table_view,
      selected_table: nil,
      datagrid_state: default_grid,
      tabs: [default_tab],
      active_tab_id: "tab_1",
      sidebar_nodes: nodes,
      selected_tree_node_id: first_id
    }

    struct(base, opts)
  end

  @doc """
  Cycles focus between main layout panes (:sidebar -> :editor -> :datagrid).
  In :table_view mode, cycles between :sidebar and :datagrid.
  """
  @spec cycle_focus(t(), :next | :prev) :: t()
  def cycle_focus(%__MODULE__{focus: current, active_view: active_view} = app, direction \\ :next) do
    panes = if active_view == :table_view, do: [:sidebar, :datagrid], else: @panes
    idx = Enum.find_index(panes, &(&1 == current)) || 0
    cnt = length(panes)

    next_idx =
      case direction do
        :next -> rem(idx + 1, cnt)
        :prev -> rem(idx - 1 + cnt, cnt)
      end

    %{app | focus: Enum.at(panes, next_idx)}
  end

  @doc """
  Switches right side active view mode between :table_view and :query_view.
  """
  @spec switch_view(t(), :table_view | :query_view) :: t()
  def switch_view(%__MODULE__{} = app, view) when view in [:table_view, :query_view] do
    new_focus =
      if view == :table_view and app.focus == :editor do
        :datagrid
      else
        app.focus
      end

    %{app | active_view: view, focus: new_focus}
  end

  def switch_view(app, _invalid_view), do: app

  @doc """
  Sets active focus pane if valid.
  """
  @spec set_focus(t(), atom()) :: t()
  def set_focus(%__MODULE__{} = app, pane) when pane in @panes do
    %{app | focus: pane}
  end

  def set_focus(%__MODULE__{} = app, _invalid_pane), do: app

  @doc """
  Opens a new editor tab and sets it active.
  """
  @spec open_tab(t(), keyword()) :: t()
  def open_tab(%__MODULE__{tabs: tabs} = app, tab_opts \\ []) do
    tab_num = length(tabs) + 1
    tab_id = "tab_#{tab_num}"
    name = Keyword.get(tab_opts, :name, "Query #{tab_num}")
    content = Keyword.get(tab_opts, :content, "")

    new_tab = %{
      id: tab_id,
      name: name,
      content: content,
      cursor: {0, 0}
    }

    %{app | tabs: tabs ++ [new_tab], active_tab_id: tab_id}
  end

  @doc """
  Closes tab with given ID and adjusts active tab.
  """
  @spec close_tab(t(), String.t()) :: t()
  def close_tab(%__MODULE__{tabs: tabs, active_tab_id: active_id} = app, tab_id) do
    remaining = Enum.reject(tabs, &(&1.id == tab_id))

    new_active_id =
      if active_id == tab_id do
        case remaining do
          [last | _] -> last.id
          [] -> nil
        end
      else
        active_id
      end

    %{app | tabs: remaining, active_tab_id: new_active_id}
  end

  @doc """
  Switches active tab to the specified tab ID if present.
  """
  @spec switch_tab(t(), String.t()) :: t()
  def switch_tab(%__MODULE__{tabs: tabs} = app, tab_id) do
    if Enum.any?(tabs, &(&1.id == tab_id)) do
      %{app | active_tab_id: tab_id}
    else
      app
    end
  end

  @doc """
  Pushes a modal overlay map to the top of the modals stack.
  """
  @spec push_modal(t(), map()) :: t()
  def push_modal(%__MODULE__{modals: modals} = app, modal) when is_map(modal) do
    %{app | modals: [modal | modals]}
  end

  @doc """
  Pops top modal from stack, returning {popped_modal, updated_app}.
  """
  @spec pop_modal(t()) :: {map() | nil, t()}
  def pop_modal(%__MODULE__{modals: [top | rest]} = app) do
    {top, %{app | modals: rest}}
  end

  def pop_modal(%__MODULE__{modals: []} = app) do
    {nil, app}
  end

  @doc """
  Dispatches keyboard events to focus pane or modal handler.
  """
  @spec handle_key(t(), any()) :: t()
  def handle_key(%__MODULE__{modals: [top | rest]} = app, key) do
    case key do
      :esc ->
        {_popped, app} = pop_modal(app)
        app

      _ ->
        cond do
          match?(%DBData.UI.Components.ConnectionModal{}, top) or match?(%{type: :connection_modal}, top) ->
            cm = case top do
              %DBData.UI.Components.ConnectionModal{} = modal -> modal
              _ -> DBData.UI.Components.ConnectionModal.new()
            end

            case DBData.UI.Components.ConnectionModal.handle_key(cm, key) do
              {:save, modal} ->
                profile = DBData.UI.Components.ConnectionModal.to_profile(modal)
                try do
                  DBData.ConfigStore.put_profile(profile)
                catch
                  _, _ -> :ok
                end

                {_popped, app} = pop_modal(app)
                updated_nodes = Sidebar.load_nodes()
                %{app | sidebar_nodes: updated_nodes, selected_tree_node_id: profile.id}

              {:cancel, _modal} ->
                {_popped, app} = pop_modal(app)
                app

              %DBData.UI.Components.ConnectionModal{} = updated_modal ->
                %{app | modals: [updated_modal | rest]}
            end

          match?(%DBData.UI.Components.CellDetailModal{}, top) or match?(%{type: :cell_detail_modal}, top) ->
            case key do
              k when k in [:enter, :space, :esc, "q", "Q"] ->
                {_popped, app} = pop_modal(app)
                app

              _ ->
                cell_modal =
                  case top do
                    %DBData.UI.Components.CellDetailModal{} = m -> m
                    %{raw_value: val} -> DBData.UI.Components.CellDetailModal.new(val, column: Map.get(top, :column))
                    %{content: val} -> DBData.UI.Components.CellDetailModal.new(val, column: Map.get(top, :column))
                    _ -> DBData.UI.Components.CellDetailModal.new("")
                  end

                updated = DBData.UI.Components.CellDetailModal.handle_key(cell_modal, key)
                %{app | modals: [updated | rest]}
            end

          match?(%DBData.UI.Components.FilterExportModal{}, top) ->
            case DBData.UI.Components.FilterExportModal.handle_key(top, key) do
              {:apply, _res, modal} ->
                {_popped, app} = pop_modal(app)
                %{app | status_message: "Filter applied: " <> modal.where_clause}

              {:cancel, _modal} ->
                {_popped, app} = pop_modal(app)
                app

              %DBData.UI.Components.FilterExportModal{} = updated_modal ->
                %{app | modals: [updated_modal | rest]}
            end

          match?(%{type: :filter_modal}, top) ->
            fe_modal = DBData.UI.Components.FilterExportModal.new(:filter)

            case DBData.UI.Components.FilterExportModal.handle_key(fe_modal, key) do
              {:apply, _res, _m} ->
                {_popped, app} = pop_modal(app)
                app

              {:cancel, _m} ->
                {_popped, app} = pop_modal(app)
                app

              %DBData.UI.Components.FilterExportModal{} = updated_modal ->
                %{app | modals: [updated_modal | rest]}
            end

          match?(%{type: :export_modal}, top) ->
            fe_modal = DBData.UI.Components.FilterExportModal.new(:export)

            case DBData.UI.Components.FilterExportModal.handle_key(fe_modal, key) do
              {:apply, _res, _m} ->
                {_popped, app} = pop_modal(app)
                app

              {:cancel, _m} ->
                {_popped, app} = pop_modal(app)
                app

              %DBData.UI.Components.FilterExportModal{} = updated_modal ->
                %{app | modals: [updated_modal | rest]}
            end

          true ->
            if key in [:enter, :space] do
              {_popped, app} = pop_modal(app)
              app
            else
              app
            end
        end
    end
  end

  def handle_key(%__MODULE__{} = app, :tab), do: cycle_focus(app, :next)
  def handle_key(%__MODULE__{} = app, :shift_tab), do: cycle_focus(app, :prev)
  def handle_key(%__MODULE__{} = app, :f1), do: switch_view(app, :table_view)
  def handle_key(%__MODULE__{} = app, :f2), do: switch_view(app, :query_view)

  def handle_key(%__MODULE__{} = app, {:ctrl, "1"}), do: switch_view(app, :table_view)
  def handle_key(%__MODULE__{} = app, {:ctrl, "2"}), do: switch_view(app, :query_view)
  def handle_key(%__MODULE__{} = app, {:ctrl, "3"}), do: set_focus(app, :datagrid)

  def handle_key(%__MODULE__{focus: focus} = app, "1") when focus != :editor, do: switch_view(app, :table_view)
  def handle_key(%__MODULE__{focus: focus} = app, "2") when focus != :editor, do: switch_view(app, :query_view)
  def handle_key(%__MODULE__{focus: focus} = app, "3") when focus != :editor, do: set_focus(app, :datagrid)

  def handle_key(%__MODULE__{focus: :sidebar} = app, key) do
    Sidebar.handle_key(app, key)
  end

  def handle_key(%__MODULE__{focus: :editor} = app, key) do
    SQLEditor.handle_key(app, key)
  end

  def handle_key(%__MODULE__{focus: :datagrid} = app, key) do
    grid = app.datagrid_state || DataGrid.new()
    {app, updated_grid} = DataGrid.handle_key(app, grid, key)
    %{app | datagrid_state: updated_grid}
  end

  def handle_key(%__MODULE__{} = app, _key), do: app

  @doc """
  Handles mouse click and scroll wheel events.
  """
  @spec handle_mouse(t(), any()) :: t()
  def handle_mouse(%__MODULE__{window_size: ws, active_view: active_view} = app, {:scroll, dir, x, y}) do
    layout = Renderer.layout(ws, active_view)

    cond do
      inside_area?(x, y, layout.sidebar) ->
        Sidebar.handle_key(app, if(dir == :up, do: :up, else: :down))

      layout.datagrid.height > 0 and inside_area?(x, y, layout.datagrid) ->
        grid = app.datagrid_state || DataGrid.new()
        vh = max(1, layout.datagrid.height - 3)
        updated_grid = DataGrid.move_selection(grid, if(dir == :up, do: :up, else: :down), vh)
        %{app | datagrid_state: updated_grid, focus: :datagrid}

      true ->
        app
    end
  end

  def handle_mouse(%__MODULE__{window_size: ws, active_view: active_view} = app, {:click, x, y}) do
    layout = Renderer.layout(ws, active_view)

    cond do
      inside_area?(x, y, layout.footer) ->
        cond do
          x >= 0 and x <= 22 -> switch_view(app, :table_view)
          x >= 23 and x <= 45 -> switch_view(app, :query_view)
          true -> app
        end

      inside_area?(x, y, layout.sidebar) ->
        app = set_focus(app, :sidebar)
        row_offset = max(0, y - 1)

        visible = Sidebar.flatten_visible_nodes(app.sidebar_nodes, app.selected_tree_node_id)
        target_item = Enum.at(visible, row_offset)

        if target_item do
          app = %{app | selected_tree_node_id: target_item.id}

          if target_item.type in [:table, :view] do
            Sidebar.load_table_data(app, target_item.label)
          else
            app
          end
        else
          app
        end

      layout.editor.height > 0 and inside_area?(x, y, layout.editor) ->
        set_focus(app, :editor)

      layout.datagrid.height > 0 and inside_area?(x, y, layout.datagrid) ->
        handle_datagrid_click(app, x, y, layout)

      true ->
        app
    end
  end

  def handle_mouse(app, _event), do: app

  defp handle_datagrid_click(app, x, y, layout) do
    app = set_focus(app, :datagrid)
    grid = app.datagrid_state || DataGrid.new()

    grid_y = layout.datagrid.y
    grid_x = layout.datagrid.x

    header_offset = 2
    rel_y = y - grid_y - header_offset

    if rel_y >= 0 and grid.rows != [] do
      viewport_h = max(1, layout.datagrid.height - 3)
      max_top = max(0, length(grid.rows) - viewport_h)
      curr_scroll = min(grid.scroll_offset || 0, max_top)

      target_row = max(0, min(length(grid.rows) - 1, rel_y + curr_scroll))
      rel_x = max(0, x - grid_x - 2)

      target_col =
        if grid.columns != [] do
          widths =
            Enum.map(grid.columns, fn col_name ->
              String.length(to_string(col_name)) + 4
            end)

          Enum.reduce_while(Enum.with_index(widths), {0, 0}, fn {w, c_idx}, {acc_x, _} ->
            next_x = acc_x + w
            if rel_x < next_x do
              {:halt, {acc_x, c_idx}}
            else
              {:cont, {next_x, min(length(grid.columns) - 1, c_idx + 1)}}
            end
          end)
          |> elem(1)
        else
          0
        end

      updated_grid = %{grid | selected_cell: {target_row, target_col}, scroll_offset: curr_scroll, mode: :selecting}

      if grid.mode == :selecting and grid.selected_cell == {target_row, target_col} do
        raw_cell = grid.rows |> Enum.at(target_row, []) |> Enum.at(target_col, nil)
        col_name = Enum.at(grid.columns, target_col, "Cell")

        cell_modal = DBData.UI.Components.CellDetailModal.new(raw_cell, column: col_name, row_index: target_row + 1)

        app
        |> Map.put(:datagrid_state, updated_grid)
        |> push_modal(cell_modal)
      else
        Map.put(app, :datagrid_state, updated_grid)
      end
    else
      app
    end
  end

  defp inside_area?(x, y, %{x: ax, y: ay, width: aw, height: ah}) do
    x >= ax and x < ax + aw and y >= ay and y < ay + ah
  end
end
