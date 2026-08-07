defmodule Strata.UI.App do
  @moduledoc """
  State management for Database TUI interface.
  Manages focus panes, tabbed SQL editor, modal overlays stack, and tree view navigation.
  Integrated with ExRatatui.App behaviour for 60 FPS event-driven TUI.
  """
  use ExRatatui.App

  alias Strata.UI.Components.DataGrid
  alias Strata.UI.Components.Sidebar
  alias Strata.UI.Components.SQLEditor
  alias Strata.UI.Renderer

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
          status_message: String.t(),
          scroll_lock: {atom(), integer(), integer()} | nil,
          sidebar_scroll_offset: non_neg_integer()
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
    status_message: "Ready",
    scroll_lock: nil,
    sidebar_scroll_offset: 0
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

    kind_str =
      case kind do
        %struct_mod{} -> struct_mod |> Module.split() |> List.last() |> Macro.underscore()
        other -> to_string(other) |> Macro.underscore()
      end

    event =
      cond do
        kind_str in ["down", "click"] -> {:click, col, row}
        kind_str == "up" -> {:mouse_up, col, row}
        kind_str == "scroll_up" -> {:scroll, :up, col, row}
        kind_str == "scroll_down" -> {:scroll, :down, col, row}
        kind_str == "scroll_left" -> {:scroll, :left, col, row}
        kind_str == "scroll_right" -> {:scroll, :right, col, row}
        true -> {:mouse_event, kind, col, row}
      end

    new_state =
      case event do
        {:scroll, _dir, _x, _y} ->
          latest_event = drain_scroll_events(event)
          handle_mouse(state, latest_event)

        _other ->
          handle_mouse(state, event)
      end

    {:noreply, new_state}
  end

  def handle_event(_event, state), do: {:noreply, state}

  defp drain_scroll_events(last_event) do
    receive do
      %ExRatatui.Event.Mouse{} = mouse ->
        col = Map.get(mouse, :column) || Map.get(mouse, :x) || 0
        row = Map.get(mouse, :row) || Map.get(mouse, :y) || 0
        kind = Map.get(mouse, :kind) || Map.get(mouse, :button) || :down

        kind_str =
          case kind do
            %struct_mod{} -> struct_mod |> Module.split() |> List.last() |> Macro.underscore()
            other -> to_string(other) |> Macro.underscore()
          end

        if kind_str in ["scroll_up", "scroll_down", "scroll_left", "scroll_right"] do
          dir =
            cond do
              kind_str == "scroll_up" -> :up
              kind_str == "scroll_down" -> :down
              kind_str == "scroll_left" -> :left
              true -> :right
            end

          drain_scroll_events({:scroll, dir, col, row})
        else
          send(self(), mouse)
          last_event
        end
    after
      0 ->
        last_event
    end
  end


  @impl true
  def handle_info({:table_chunk_loaded, table_name, _offset, result}, state) do
    state =
      if state.active_view == :table_view and state.selected_table == table_name and state.datagrid_state do
        grid = state.datagrid_state

        case result do
          {:ok, _cols, new_rows} ->
            has_more = length(new_rows) == (grid.batch_size || 100)
            updated_grid = DataGrid.append_rows(grid, new_rows, has_more)
            status_msg = "Loaded +#{length(new_rows)} rows for '#{table_name}' (Total: #{length(updated_grid.rows)} rows)"
            %{state | datagrid_state: updated_grid, status_message: status_msg}

          {:error, reason} ->
            status_msg = "Error loading more rows for '#{table_name}': #{reason}"
            %{state | datagrid_state: %{grid | loading_more: false}, status_message: status_msg}
        end
      else
        state
      end

    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

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
      ctrl? and code in ["enter", "Enter"] ->
        {:ctrl, "enter"}

      ctrl? and is_binary(code) and String.length(code) == 1 ->
        {:ctrl, String.downcase(code)}

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
      case view do
        :table_view -> if app.focus == :editor, do: :datagrid, else: app.focus
        :query_view -> :editor
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
  Triggers loading the next chunk of table data for the currently selected table.
  Ignored if active view is not :table_view, no table selected, grid has_more is false, or loading_more is true.
  """
  @spec load_more_table_data(t()) :: t()
  def load_more_table_data(
        %__MODULE__{
          active_view: :table_view,
          selected_table: table_name,
          datagrid_state: %DataGrid{has_more: true, loading_more: false} = grid
        } = app
      )
      when is_binary(table_name) do
    profiles =
      try do
        Strata.ConfigStore.list_profiles()
      catch
        _, _ -> []
      end

    sel_id = app.selected_tree_node_id

    profile =
      Enum.find(profiles, fn p -> sel_id && String.starts_with?(sel_id, p.id) end) ||
        List.first(profiles)

    if profile do
      target_pid = self()
      offset = length(grid.rows)
      batch_size = grid.batch_size || 100

      Task.start(fn ->
        result = Sidebar.fetch_table_chunk(profile, table_name, offset, batch_size)
        send(target_pid, {:table_chunk_loaded, table_name, offset, result})
      end)

      %{
        app
        | datagrid_state: %{grid | loading_more: true},
          status_message: "Loading more rows for '#{table_name}'..."
      }
    else
      app
    end
  end

  def load_more_table_data(app), do: app

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
  Executes active SQL tab content against connected DB profile.
  Updates datagrid_state, switches active view to :query_view, and sets status_message.
  """
  @spec execute_sql_query(t()) :: t()
  def execute_sql_query(%__MODULE__{tabs: tabs, active_tab_id: active_id} = app) do
    active_tab = Enum.find(tabs, &(&1.id == active_id))
    sql = if active_tab, do: String.trim(active_tab.content), else: ""

    if sql == "" do
      %{app | status_message: "⚠️ Cannot execute empty SQL query"}
    else
      profiles =
        try do
          Strata.ConfigStore.list_profiles()
        catch
          _, _ -> []
        end

      sel_id = app.selected_tree_node_id

      profile =
        Enum.find(profiles, fn p -> sel_id && String.starts_with?(sel_id, p.id) end) ||
          List.first(profiles)

      if profile do
        start_time = System.monotonic_time(:millisecond)

        res =
          case Strata.ConnectionWorker.start_link(profile) do
            {:ok, pid} ->
              try do
                Strata.ConnectionWorker.execute_query(pid, sql)
              after
                Strata.ConnectionWorker.stop(pid)
              end

            {:error, reason} ->
              {:error, reason}

            _ ->
              {:error, "Failed to connect to database"}
          end

        elapsed = max(1, System.monotonic_time(:millisecond) - start_time)

        case res do
          {:ok, %{columns: cols, rows: rows}} ->
            str_rows = Enum.map(rows, fn r -> Enum.map(r, &to_string/1) end)
            grid = Strata.UI.Components.DataGrid.new(cols, str_rows)

            app
            |> switch_view(:query_view)
            |> Map.put(:datagrid_state, grid)
            |> Map.put(:status_message, "⚡ Query executed successfully (#{length(rows)} rows in #{elapsed}ms)")

          {:error, reason} ->
            msg = if is_binary(reason), do: reason, else: inspect(reason)
            err_grid = Strata.UI.Components.DataGrid.new(["error"], [[msg]])

            app
            |> switch_view(:query_view)
            |> Map.put(:datagrid_state, err_grid)
            |> Map.put(:status_message, "❌ SQL Error: #{msg}")
        end
      else
        %{app | status_message: "❌ No active database connection configured"}
      end
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
          match?(%Strata.UI.Components.ConnectionModal{}, top) or match?(%{type: :connection_modal}, top) ->
            cm = case top do
              %Strata.UI.Components.ConnectionModal{} = modal -> modal
              _ -> Strata.UI.Components.ConnectionModal.new()
            end

            case Strata.UI.Components.ConnectionModal.handle_key(cm, key) do
              {:save, modal} ->
                profile = Strata.UI.Components.ConnectionModal.to_profile(modal)
                try do
                  Strata.ConfigStore.put_profile(profile)
                catch
                  _, _ -> :ok
                end

                {_popped, app} = pop_modal(app)
                updated_nodes = Sidebar.load_nodes()
                %{app | sidebar_nodes: updated_nodes, selected_tree_node_id: profile.id}

              {:cancel, _modal} ->
                {_popped, app} = pop_modal(app)
                app

              %Strata.UI.Components.ConnectionModal{} = updated_modal ->
                %{app | modals: [updated_modal | rest]}
            end

          match?(%Strata.UI.Components.CellDetailModal{}, top) or match?(%{type: :cell_detail_modal}, top) ->
            case key do
              k when k in [:enter, :space, :esc, "q", "Q"] ->
                {_popped, app} = pop_modal(app)
                app

              _ ->
                cell_modal =
                  case top do
                    %Strata.UI.Components.CellDetailModal{} = m -> m
                    %{raw_value: val} -> Strata.UI.Components.CellDetailModal.new(val, column: Map.get(top, :column))
                    %{content: val} -> Strata.UI.Components.CellDetailModal.new(val, column: Map.get(top, :column))
                    _ -> Strata.UI.Components.CellDetailModal.new("")
                  end

                updated = Strata.UI.Components.CellDetailModal.handle_key(cell_modal, key)
                %{app | modals: [updated | rest]}
            end

          match?(%Strata.UI.Components.FilterExportModal{}, top) ->
            case Strata.UI.Components.FilterExportModal.handle_key(top, key) do
              {:apply, _res, modal} ->
                {_popped, app} = pop_modal(app)
                %{app | status_message: "Filter applied: " <> modal.where_clause}

              {:cancel, _modal} ->
                {_popped, app} = pop_modal(app)
                app

              %Strata.UI.Components.FilterExportModal{} = updated_modal ->
                %{app | modals: [updated_modal | rest]}
            end

          match?(%{type: :filter_modal}, top) ->
            fe_modal = Strata.UI.Components.FilterExportModal.new(:filter)

            case Strata.UI.Components.FilterExportModal.handle_key(fe_modal, key) do
              {:apply, _res, _m} ->
                {_popped, app} = pop_modal(app)
                app

              {:cancel, _m} ->
                {_popped, app} = pop_modal(app)
                app

              %Strata.UI.Components.FilterExportModal{} = updated_modal ->
                %{app | modals: [updated_modal | rest]}
            end

          match?(%{type: :export_modal}, top) ->
            fe_modal = Strata.UI.Components.FilterExportModal.new(:export)

            case Strata.UI.Components.FilterExportModal.handle_key(fe_modal, key) do
              {:apply, _res, _m} ->
                {_popped, app} = pop_modal(app)
                app

              {:cancel, _m} ->
                {_popped, app} = pop_modal(app)
                app

              %Strata.UI.Components.FilterExportModal{} = updated_modal ->
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

  def handle_key(%__MODULE__{} = app, {:ctrl, "enter"}), do: execute_sql_query(app)
  def handle_key(%__MODULE__{} = app, {:ctrl, "r"}), do: execute_sql_query(app)
  def handle_key(%__MODULE__{} = app, {:ctrl, "t"}), do: open_tab(app)
  def handle_key(%__MODULE__{} = app, {:ctrl, "w"}), do: close_tab(app, app.active_tab_id)

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
    case key do
      :esc -> set_focus(app, :datagrid)
      {:ctrl, "enter"} -> execute_sql_query(app)
      {:ctrl, "r"} -> execute_sql_query(app)
      {:ctrl, "t"} -> open_tab(app)
      {:ctrl, "w"} -> close_tab(app, app.active_tab_id)
      _ -> SQLEditor.handle_key(app, key)
    end
  end

  def handle_key(%__MODULE__{focus: :datagrid} = app, key) do
    layout = Renderer.layout(app.window_size, app.active_view)
    vh = max(1, layout.datagrid.height - 3)
    max_w = max(1, layout.datagrid.width - 3)

    grid = app.datagrid_state || DataGrid.new()
    {app, updated_grid} = DataGrid.handle_key(app, grid, key, viewport_h: vh, max_width: max_w)
    app = %{app | datagrid_state: updated_grid}

    if app.active_view == :table_view and key in [:down, :page_down, :end, "j", "J"] do
      if DataGrid.near_bottom?(updated_grid, vh, 25) do
        load_more_table_data(app)
      else
        app
      end
    else
      app
    end
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
        visible = Sidebar.flatten_visible_nodes(app.sidebar_nodes, app.selected_tree_node_id)
        sidebar_viewport_h = max(1, layout.sidebar.height - 2)
        total = length(visible)
        current_offset = app.sidebar_scroll_offset || 0
        max_offset = max(0, total - sidebar_viewport_h)

        new_offset =
          if dir in [:up, :left, :scroll_up, :scroll_left] do
            max(0, current_offset - 1)
          else
            min(current_offset + 1, max_offset)
          end

        # Also move the selected node if it falls outside the viewport
        selected_idx = Enum.find_index(visible, &(&1.id == app.selected_tree_node_id)) || 0
        new_selected_idx =
          cond do
            selected_idx < new_offset -> new_offset
            selected_idx >= new_offset + sidebar_viewport_h -> new_offset + sidebar_viewport_h - 1
            true -> selected_idx
          end

        new_selected_id =
          case Enum.at(visible, new_selected_idx) do
            nil -> app.selected_tree_node_id
            node -> node.id
          end

        %{app | sidebar_scroll_offset: new_offset, selected_tree_node_id: new_selected_id}

      layout.datagrid.height > 0 and inside_area?(x, y, layout.datagrid) ->
        grid = app.datagrid_state || DataGrid.new()
        vh = max(1, layout.datagrid.height - 3)
        max_w = max(1, layout.datagrid.width - 3)

        is_bottom_bar? = y >= layout.datagrid.y + layout.datagrid.height - 1

        raw_direction =
          cond do
            dir in [:left, :scroll_left] -> :left
            dir in [:right, :scroll_right] -> :right
            is_bottom_bar? and dir in [:up, :scroll_up] -> :left
            is_bottom_bar? and dir in [:down, :scroll_down] -> :right
            dir in [:up, :scroll_up] -> :up
            true -> :down
          end

        raw_axis = if raw_direction in [:left, :right], do: :horizontal, else: :vertical
        now = System.monotonic_time(:millisecond)

        {locked_axis, last_time, burst_count} = app.scroll_lock || {nil, 0, 0}
        dt = now - last_time
        idle_timeout? = dt > 150

        {current_axis, new_burst_count, new_app_lock} =
          if idle_timeout? or locked_axis == nil do
            {raw_axis, 1, {raw_axis, now, 1}}
          else
            cnt = burst_count + 1
            {locked_axis, cnt, {locked_axis, now, cnt}}
          end

        # Check for macOS post-liftoff inertia tail (slowing events after hand left the trackpad)
        is_inertia_tail? = not idle_timeout? and new_burst_count > 4 and dt > 35

        # Horizontal scroll dampening: throttle horizontal events to 50% stride for smooth, controlled column scrolling
        is_h_damped? = raw_axis == :horizontal and not idle_timeout? and rem(new_burst_count, 2) != 0

        if raw_axis == current_axis and not is_inertia_tail? and not is_h_damped? do
          step = if raw_direction in [:up, :down], do: 3, else: 1
          updated_grid = DataGrid.move_selection(grid, raw_direction, vh, max_width: max_w, step: step)
          app = %{app | datagrid_state: updated_grid, focus: :datagrid, scroll_lock: new_app_lock}

          if active_view == :table_view and raw_direction == :down and DataGrid.near_bottom?(updated_grid, vh, 25) do
            load_more_table_data(app)
          else
            app
          end
        else
          # Drop conflicting diagonal drift event, post-liftoff inertia tail, or damped horizontal tick
          %{app | scroll_lock: new_app_lock}
        end

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
        # Account for top border (1 line)
        rel_y = y - layout.sidebar.y - 1

        visible = Sidebar.flatten_visible_nodes(app.sidebar_nodes, app.selected_tree_node_id)
        # Viewport height = area height minus top and bottom borders
        sidebar_viewport_h = max(1, layout.sidebar.height - 2)

        # Use the tracked scroll offset directly
        sidebar_scroll_top = app.sidebar_scroll_offset || 0
        target_idx = sidebar_scroll_top + rel_y

        if rel_y >= 0 and rel_y < sidebar_viewport_h and target_idx >= 0 and target_idx < length(visible) do
          target_item = Enum.at(visible, target_idx)

          if target_item do
            # Calculate initial scroll offset for selected item
            new_offset = clamp_sidebar_offset(sidebar_scroll_top, target_idx, sidebar_viewport_h, length(visible))
            app = %{app | selected_tree_node_id: target_item.id, sidebar_scroll_offset: new_offset}

            app =
              if target_item.type in [:table, :view] do
                Sidebar.load_table_data(app, target_item.label)
              else
                Sidebar.handle_key(app, :enter)
              end

            # Re-clamp offset against updated tree (in case expand/collapse changed tree length)
            updated_visible = Sidebar.flatten_visible_nodes(app.sidebar_nodes, app.selected_tree_node_id)
            updated_sel_idx = Enum.find_index(updated_visible, &(&1.id == app.selected_tree_node_id)) || 0
            final_offset = clamp_sidebar_offset(app.sidebar_scroll_offset || 0, updated_sel_idx, sidebar_viewport_h, length(updated_visible))

            %{app | sidebar_scroll_offset: final_offset}
          else
            app
          end
        else
          app
        end

      layout.editor.height > 0 and inside_area?(x, y, layout.editor) ->
        app = set_focus(app, :editor)

        if y == layout.editor.y and app.tabs != [] do
          rel_x = max(0, x - layout.editor.x)
          tab_idx = min(length(app.tabs) - 1, div(rel_x, 14))
          target_tab = Enum.at(app.tabs, tab_idx)
          if target_tab, do: switch_tab(app, target_tab.id), else: app
        else
          app
        end

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
    is_bottom_bar? = y >= layout.datagrid.y + layout.datagrid.height - 1

    cond do
      is_bottom_bar? ->
        vh = max(1, layout.datagrid.height - 3)
        max_w = max(1, layout.datagrid.width - 3)
        mid_x = grid_x + div(layout.datagrid.width, 2)
        dir = if x < mid_x, do: :left, else: :right
        updated_grid = DataGrid.move_selection(grid, dir, vh, max_width: max_w)
        %{app | datagrid_state: updated_grid}

      rel_y >= 0 and grid.rows != [] ->
        viewport_h = max(1, layout.datagrid.height - 3)
        all_rows = grid.rows
        total_r = grid.total_rows || length(all_rows)
        max_top = max(0, total_r - viewport_h)
        curr_scroll = min(grid.scroll_offset || 0, max_top)

        visible_row_count = max(0, min(viewport_h, total_r - curr_scroll))

        if rel_y < visible_row_count do
          target_row = curr_scroll + rel_y
          rel_x = max(0, x - grid_x - 1)

          max_width = max(1, layout.datagrid.width - 3)
          {_local_col, target_col, col_offset} = DataGrid.col_at_x(grid, rel_x, max_width)

          already_selected? = grid.mode == :selecting and grid.selected_cell == {target_row, target_col}

          new_scroll =
            cond do
              target_row < curr_scroll -> max(0, target_row)
              target_row >= curr_scroll + viewport_h -> min(max_top, target_row - viewport_h + 1)
              true -> curr_scroll
            end

          updated_grid = %{
            grid
            | selected_cell: {target_row, target_col},
              scroll_offset: new_scroll,
              col_offset: col_offset,
              mode: :selecting
          }

          app = Map.put(app, :datagrid_state, updated_grid)

          if already_selected? do
            raw_cell = grid.rows |> Enum.at(target_row, []) |> Enum.at(target_col, nil)
            col_name = Enum.at(grid.columns, target_col, "Cell")
            cell_modal = Strata.UI.Components.CellDetailModal.new(raw_cell, column: col_name, row_index: target_row + 1)
            push_modal(app, cell_modal)
          else
            app
          end
        else
          app
        end

      true ->
        app
    end
  end

  defp clamp_sidebar_offset(current_offset, selected_idx, viewport_h, total) do
    max_offset = max(0, total - viewport_h)
    # If selected is above the current viewport, scroll up to show it
    # If selected is below the current viewport, scroll down to show it
    # Otherwise keep the current offset
    cond do
      selected_idx < current_offset ->
        max(0, selected_idx)
      selected_idx >= current_offset + viewport_h ->
        min(selected_idx - viewport_h + 1, max_offset)
      true ->
        min(current_offset, max_offset)
    end
  end

  defp inside_area?(x, y, %{x: ax, y: ay, width: aw, height: ah}) do
    x >= ax and x < ax + aw and y >= ay and y < ay + ah
  end
end
