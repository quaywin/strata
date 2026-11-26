defmodule Strata.UI.App do
  @moduledoc """
  State management for Database TUI interface.
  Manages focus panes, tabbed SQL editor, modal overlays stack, async DB operations,
  ETS caching, and tree view navigation.
  Integrated with ExRatatui.App behaviour for 60 FPS event-driven TUI.
  """
  use ExRatatui.App

  alias Strata.UI.Components.ActionsModal
  alias Strata.UI.Components.CellDetailModal
  alias Strata.UI.Components.ConnectionModal
  alias Strata.UI.Components.DataGrid
  alias Strata.UI.Components.FilterExportModal
  alias Strata.UI.Components.Sidebar
  alias Strata.UI.Components.SQLEditor
  alias Strata.UI.Components.SSHModal
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
          selected_schema: String.t() | nil,
          table_request_id: integer() | nil,
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
          sidebar_scroll_offset: non_neg_integer(),
          connection_statuses: map(),
          last_grid_click: {{non_neg_integer(), non_neg_integer()}, integer()} | nil,
          terminal: boolean(),
          throbber_step: non_neg_integer(),
          throbber_timer: reference() | nil,
          inline_input_ref: reference() | nil,
          structure_restore_grid: DataGrid.t() | nil,
          active_filter: map() | nil,
          filter_bar_open: boolean(),
          filter_bar_focused: boolean(),
          filter_bar_mode: :builder | :raw,
          filter_bar_focus_part: :column | :op | :value,
          filter_bar_col: String.t(),
          filter_bar_op: atom(),
          filter_bar_ref: reference() | nil,
          filter_bar_text: String.t(),
          filter_history: map(),
          filter_history_idx: non_neg_integer() | nil,
          filter_history_draft: map() | nil,
          filter_dropdown: :column | :op | nil,
          filter_dropdown_idx: non_neg_integer(),
          filter_dropdown_search: String.t(),
          sort_picker_open: boolean(),
          sort_picker_idx: non_neg_integer(),
          sort_picker_search: String.t(),
          inspector_open: boolean(),
          inspector_value_scroll: non_neg_integer(),
          inspector_summary_scroll: non_neg_integer(),
          inspector_format: :auto | :json | :text | :raw,
          sidebar_filter: String.t(),
          sidebar_filter_active: boolean(),
          drag_anchor: {integer(), integer()} | nil,
          text_selection: {{integer(), integer()}, {integer(), integer()}} | nil,
          selection_screen: map() | nil,
          selection_bounds: map() | nil
        }

  defstruct focus: :sidebar,
            active_view: :table_view,
            selected_table: nil,
            selected_schema: nil,
            table_request_id: nil,
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
            sidebar_scroll_offset: 0,
            connection_statuses: %{},
            last_grid_click: nil,
            terminal: false,
            throbber_step: 0,
            throbber_timer: nil,
            inline_input_ref: nil,
            structure_restore_grid: nil,
            active_filter: nil,
            filter_bar_open: false,
            filter_bar_focused: false,
            filter_bar_mode: :builder,
            filter_bar_focus_part: :value,
            filter_bar_col: "* All",
            filter_bar_op: :contains,
            filter_bar_ref: nil,
            filter_bar_text: "",
            filter_history: %{},
            filter_history_idx: nil,
            filter_history_draft: nil,
            filter_dropdown: nil,
            filter_dropdown_idx: 0,
            filter_dropdown_search: "",
            sort_picker_open: false,
            sort_picker_idx: 0,
            sort_picker_search: "",
            inspector_open: false,
            inspector_value_scroll: 0,
            inspector_summary_scroll: 0,
            inspector_format: :auto,
            sidebar_filter: "",
            sidebar_filter_active: false,
            drag_anchor: nil,
            text_selection: nil,
            selection_screen: nil,
            selection_bounds: nil

  @panes [:sidebar, :editor, :datagrid]

  # --- ExRatatui.App Callbacks ---

  @impl true
  def mount(opts) do
    if Process.whereis(Strata.PubSub) do
      Phoenix.PubSub.subscribe(Strata.PubSub, "config:profiles")
      Phoenix.PubSub.subscribe(Strata.PubSub, "connections")
    end

    terminal? = Keyword.get(opts, :terminal, is_nil(Keyword.get(opts, :test_mode)))

    {w, h} =
      if terminal? do
        case ExRatatui.terminal_size() do
          {tw, th} when is_integer(tw) and is_integer(th) -> {tw, th}
          {:error, _} -> {120, 40}
        end
      else
        case Keyword.get(opts, :test_mode) do
          {tw, th} when is_integer(tw) and is_integer(th) -> {tw, th}
          _ -> {120, 40}
        end
      end

    state = new(window_size: {w, h}, terminal: terminal?)

    if Keyword.get(opts, :bootstrap, true) do
      send(self(), :bootstrap)
    end

    {:ok, state}
  end

  @impl true
  def handle_event(%ExRatatui.Event.Resize{width: w, height: h}, state) do
    {:noreply,
     %{
       state
       | window_size: {w, h},
         drag_anchor: nil,
         text_selection: nil,
         selection_screen: nil,
         selection_bounds: nil
     }}
  end

  def handle_event(%ExRatatui.Event.Key{kind: "release"}, state) do
    {:noreply, state, render?: false}
  end

  def handle_event(%ExRatatui.Event.Key{code: code, modifiers: modifiers}, state) do
    mapped_key = map_ex_ratatui_key(code, modifiers)

    cond do
      match?(%DataGrid{editing_cell: {_r, _c}}, state.datagrid_state) ->
        {:noreply, handle_inline_edit_key(state, mapped_key)}

      state.filter_bar_open and state.filter_bar_focused ->
        {:noreply, handle_filter_bar_key(state, mapped_key)}

      state.sort_picker_open ->
        {:noreply, handle_sort_picker_key(state, mapped_key)}

      mapped_key in ["q", "Q"] and state.focus != :editor and Enum.empty?(state.modals) ->
        {:stop, state}

      match?([%ConnectionModal{focused_field: :test_button} | _], state.modals) and
          mapped_key in [:enter, :space] ->
        {:noreply, test_connection_async(state)}

      match?([%SSHModal{focused_field: :test_button} | _], state.modals) and
          mapped_key in [:enter, :space] ->
        {:noreply, test_ssh_async(state)}

      mapped_key in [{:ctrl, "enter"}, {:ctrl, "r"}] and Enum.empty?(state.modals) ->
        {:noreply, execute_sql_query_async(state)}

      state.focus == :sidebar and state.sidebar_filter_active and Enum.empty?(state.modals) ->
        {:noreply, handle_sidebar_filter_key(state, mapped_key)}

      state.focus == :sidebar and mapped_key in [:enter, :space, " ", "r", "R", :f5] and
          Enum.empty?(state.modals) ->
        handle_sidebar_action_async(state, mapped_key)

      true ->
        new_state = handle_key(state, mapped_key)
        {:noreply, new_state}
    end
  end

  def handle_event(%ExRatatui.Event.Paste{content: text}, state) do
    {:noreply, paste_text(state, text)}
  end

  def handle_event(%ExRatatui.Event.Mouse{x: col, y: row, kind: kind, button: button}, state) do
    col = col || 0
    row = row || 0
    kind_str = normalize_mouse_kind(kind)
    left_button? = left_mouse_button?(button)

    cond do
      kind_str == "moved" ->
        {:noreply, state, render?: false, pointer: pointer_for_position(state, col, row)}

      kind_str in ["down", "click"] and left_button? ->
        had_sel? = state.text_selection != nil

        new_state = %{
          state
          | drag_anchor: {col, row},
            text_selection: nil,
            selection_screen: nil,
            selection_bounds: nil
        }

        {:noreply, new_state,
         render?: had_sel?, pointer: pointer_for_position(new_state, col, row)}

      kind_str == "drag" and left_button? ->
        latest_drag = drain_drag_events({:drag, col, row})
        new_state = handle_drag_select(state, latest_drag)
        {:noreply, new_state, pointer: pointer_for_position(new_state, col, row)}

      kind_str == "up" and left_button? ->
        new_state = handle_drag_finish(state, col, row)
        {:noreply, new_state, pointer: pointer_for_position(new_state, col, row)}

      kind_str in ["down", "click", "drag", "up"] ->
        {:noreply, state, render?: false, pointer: pointer_for_position(state, col, row)}

      true ->
        event =
          case kind_str do
            "scroll_up" -> {:scroll, :up, col, row}
            "scroll_down" -> {:scroll, :down, col, row}
            "scroll_left" -> {:scroll, :left, col, row}
            "scroll_right" -> {:scroll, :right, col, row}
            _ -> {:mouse_event, kind, col, row}
          end

        {new_state, should_render?} =
          case event do
            {:scroll, _dir, _x, _y} ->
              latest_event = drain_scroll_events(event)

              base_state =
                if state.text_selection != nil do
                  %{
                    state
                    | drag_anchor: nil,
                      text_selection: nil,
                      selection_screen: nil,
                      selection_bounds: nil
                  }
                else
                  state
                end

              scrolled_state = handle_mouse(base_state, latest_event)
              {scrolled_state, scroll_visual_changed?(state, scrolled_state)}

            _other ->
              {handle_mouse(state, event), true}
          end

        {:noreply, new_state,
         render?: should_render?, pointer: pointer_for_position(new_state, col, row)}
    end
  end

  def handle_event(_event, state), do: {:noreply, state, render?: false}

  defp left_mouse_button?(button), do: button in ["left", :left, nil, ""]

  defp scroll_visual_changed?(old_state, new_state) do
    old_grid = old_state.datagrid_state
    new_grid = new_state.datagrid_state

    grid_changed? =
      case {old_grid, new_grid} do
        {nil, nil} ->
          false

        {%DataGrid{} = og, %DataGrid{} = ng} ->
          og.scroll_offset != ng.scroll_offset or
            og.col_offset != ng.col_offset or
            og.selected_cell != ng.selected_cell or
            og.loading_more != ng.loading_more or
            og.total_rows != ng.total_rows or
            og.mode != ng.mode

        _ ->
          true
      end

    grid_changed? or
      old_state.text_selection != new_state.text_selection or
      old_state.focus != new_state.focus or
      old_state.sidebar_scroll_offset != new_state.sidebar_scroll_offset or
      old_state.selected_tree_node_id != new_state.selected_tree_node_id or
      old_state.inspector_value_scroll != new_state.inspector_value_scroll or
      old_state.inspector_summary_scroll != new_state.inspector_summary_scroll or
      old_state.filter_dropdown_idx != new_state.filter_dropdown_idx or
      old_state.sort_picker_idx != new_state.sort_picker_idx or
      old_state.status_message != new_state.status_message or
      old_state.modals != new_state.modals
  end

  defp normalize_mouse_kind(kind) do
    case kind do
      %struct_mod{} -> struct_mod |> Module.split() |> List.last() |> Macro.underscore()
      other -> to_string(other) |> Macro.underscore()
    end
  end

  defp drain_scroll_events(last_event) do
    receive do
      %ExRatatui.Event.Mouse{x: col, y: row, kind: kind} = msg ->
        col = col || 0
        row = row || 0
        kind_str = normalize_mouse_kind(kind)

        if kind_str in ["scroll_up", "scroll_down", "scroll_left", "scroll_right"] do
          dir =
            case kind_str do
              "scroll_up" -> :up
              "scroll_down" -> :down
              "scroll_left" -> :left
              "scroll_right" -> :right
            end

          drain_scroll_events({:scroll, dir, col, row})
        else
          send(self(), msg)
          last_event
        end
    after
      0 ->
        last_event
    end
  end

  defp drain_drag_events(last_event) do
    receive do
      %ExRatatui.Event.Mouse{x: col, y: row, kind: kind, button: button} = msg ->
        col = col || 0
        row = row || 0

        if normalize_mouse_kind(kind) == "drag" and left_mouse_button?(button) do
          drain_drag_events({:drag, col, row})
        else
          send(self(), msg)
          last_event
        end
    after
      0 ->
        last_event
    end
  end

  defp handle_drag_select(
         %__MODULE__{drag_anchor: {ax, ay} = anchor, text_selection: existing} = state,
         {:drag, x, y}
       )
       when {x, y} != {ax, ay} or not is_nil(existing) do
    state =
      if is_nil(state.selection_screen) and Map.get(state, :terminal, false) do
        case ExRatatui.terminal_size() do
          {tw, th} when is_integer(tw) and is_integer(th) and tw > 0 and th > 0 ->
            %{state | window_size: {tw, th}}

          _ ->
            state
        end
      else
        state
      end

    screen = state.selection_screen || Strata.UI.Selection.capture_screen(state)
    bounds = state.selection_bounds || Strata.UI.Selection.bounds_for_anchor(state, anchor)

    %{
      state
      | selection_screen: screen,
        selection_bounds: bounds,
        text_selection: {anchor, {x, y}},
        last_grid_click: nil
    }
  end

  defp handle_drag_select(state, _event), do: state

  defp handle_drag_finish(
         %__MODULE__{
           text_selection: {anchor, drag_end},
           selection_screen: %{} = screen,
           selection_bounds: %{} = bounds
         } = state,
         _x,
         _y
       ) do
    text = Strata.UI.Selection.extract_text(screen, anchor, drag_end, bounds)

    status =
      if text != "" do
        case Strata.Clipboard.copy(text) do
          :ok ->
            preview =
              text
              |> String.replace(~r/\s+/, " ")
              |> then(fn s ->
                if String.length(s) > 34, do: String.slice(s, 0, 31) <> "...", else: s
              end)

            "📋 Copied selection: #{preview}"

          {:error, _} ->
            "📋 Copy selection failed (no clipboard tool)"
        end
      else
        state.status_message
      end

    %{
      state
      | drag_anchor: nil,
        text_selection: nil,
        selection_screen: nil,
        selection_bounds: nil,
        status_message: status
    }
  end

  defp handle_drag_finish(%__MODULE__{drag_anchor: {_ax, _ay}} = state, x, y) do
    %{state | drag_anchor: nil, text_selection: nil, selection_screen: nil, selection_bounds: nil}
    |> handle_mouse_live({:click, x, y})
  end

  defp handle_drag_finish(state, _x, _y) do
    %{state | drag_anchor: nil, text_selection: nil, selection_screen: nil, selection_bounds: nil}
  end

  defp handle_sidebar_action_async(state, key) do
    visible = Sidebar.visible_nodes(state)
    selected_item = Enum.find(visible, &(&1.id == state.selected_tree_node_id))

    offline_or_loading? =
      selected_item != nil and is_binary(selected_item.id) and
        (String.ends_with?(selected_item.id, "_status") or
           String.ends_with?(selected_item.id, "_loading"))

    cond do
      key == :f5 ->
        {:noreply, refresh_selected_connection_schema_async(state)}

      key in ["r", "R"] and
          (is_nil(selected_item) or selected_item.type in [:connection, :schema]) ->
        {:noreply, refresh_selected_connection_schema_async(state)}

      offline_or_loading? and key in [:enter, :space, " "] ->
        {:noreply, refresh_selected_connection_schema_async(state)}

      selected_item && selected_item.type in [:table, :view] ->
        refresh? = key in ["r", "R"]

        {:noreply,
         load_table_async(%{state | sidebar_filter_active: false}, selected_item.label,
           refresh: refresh?
         )}

      true ->
        {:noreply, Sidebar.handle_key(state, key)}
    end
  end

  defp handle_sidebar_filter_key(state, key) do
    case key do
      :esc ->
        %{state | sidebar_filter: "", sidebar_filter_active: false, sidebar_scroll_offset: 0}

      :backspace ->
        curr = state.sidebar_filter || ""
        next = String.slice(curr, 0, max(0, String.length(curr) - 1))
        sync_sidebar_filter_selection(%{state | sidebar_filter: next, sidebar_scroll_offset: 0})

      dir when dir in [:up, :down] ->
        Sidebar.handle_key(%{state | sidebar_filter_active: false}, dir)
        |> Map.put(:sidebar_filter_active, true)

      :enter ->
        visible = Sidebar.visible_nodes(state)
        selected = Enum.find(visible, &(&1.id == state.selected_tree_node_id))

        target =
          if selected && selected.type in [:table, :view],
            do: selected,
            else: Enum.find(visible, &(&1.type in [:table, :view]))

        if target do
          state
          |> Map.put(:selected_tree_node_id, target.id)
          |> Map.put(:sidebar_filter_active, false)
          |> load_table_async(target.label)
        else
          %{state | sidebar_filter_active: false}
        end

      k when is_binary(k) ->
        if String.length(k) == 1 do
          next = (state.sidebar_filter || "") <> k
          sync_sidebar_filter_selection(%{state | sidebar_filter: next, sidebar_scroll_offset: 0})
        else
          state
        end

      _ ->
        state
    end
  end

  defp sync_sidebar_filter_selection(state) do
    visible = Sidebar.visible_nodes(state)

    next_sel =
      Enum.find(visible, &(&1.type in [:table, :view])) ||
        List.first(visible)

    %{state | selected_tree_node_id: (next_sel && next_sel.id) || state.selected_tree_node_id}
  end

  defp handle_mouse_live(%__MODULE__{modals: []} = state, {:click, x, y}) do
    layout = Renderer.layout(state.window_size, state.active_view)

    if inside_area?(x, y, layout.sidebar) do
      state =
        state
        |> cancel_inline_edit_if_active()
        |> set_focus(:sidebar)

      rel_y = y - layout.sidebar.y - 1
      visible = Sidebar.visible_nodes(state)
      sidebar_viewport_h = max(1, layout.sidebar.height - 2)
      sidebar_scroll_top = state.sidebar_scroll_offset || 0
      target_idx = sidebar_scroll_top + rel_y

      if rel_y >= 0 and rel_y < sidebar_viewport_h and target_idx >= 0 and
           target_idx < length(visible) do
        target_item = Enum.at(visible, target_idx)

        new_offset =
          clamp_sidebar_offset(
            sidebar_scroll_top,
            target_idx,
            sidebar_viewport_h,
            length(visible)
          )

        state = %{
          state
          | selected_tree_node_id: target_item.id,
            sidebar_scroll_offset: new_offset
        }

        if target_item.type in [:table, :view] do
          load_table_async(state, target_item.label)
        else
          updated = Sidebar.handle_key(state, :enter)

          updated_visible =
            Sidebar.flatten_visible_nodes(updated.sidebar_nodes, updated.selected_tree_node_id)

          updated_sel_idx =
            Enum.find_index(updated_visible, &(&1.id == updated.selected_tree_node_id)) || 0

          final_offset =
            clamp_sidebar_offset(
              updated.sidebar_scroll_offset || 0,
              updated_sel_idx,
              sidebar_viewport_h,
              length(updated_visible)
            )

          %{updated | sidebar_scroll_offset: final_offset}
        end
      else
        state
      end
    else
      handle_mouse(state, {:click, x, y})
    end
  end

  defp handle_mouse_live(state, {:click, x, y}) do
    handle_mouse(state, {:click, x, y})
  end

  @impl true
  def handle_info(:bootstrap, state) do
    profiles = safe_list_profiles()
    {:noreply, start_schema_stream_tasks(state, profiles), render?: false}
  end

  def handle_info({:schemas_loaded, nodes}, state) when is_list(nodes) do
    first_id =
      case List.first(nodes) do
        nil -> state.selected_tree_node_id
        n -> state.selected_tree_node_id || n.id
      end

    {:noreply, %{state | sidebar_nodes: nodes, selected_tree_node_id: first_id}}
  end

  def handle_info({:connection_schema_loaded, profile_id, new_node}, state)
      when is_binary(profile_id) do
    updated_nodes = upsert_connection_node(state.sidebar_nodes, profile_id, new_node)

    first_id =
      case List.first(updated_nodes) do
        nil -> state.selected_tree_node_id
        n -> state.selected_tree_node_id || n.id
      end

    {:noreply, %{state | sidebar_nodes: updated_nodes, selected_tree_node_id: first_id}}
  end

  def handle_info({:profiles_updated, profiles}, state) when is_list(profiles) do
    nodes = Sidebar.load_nodes()
    state = %{state | sidebar_nodes: nodes}
    {:noreply, start_schema_stream_tasks(state, profiles)}
  end

  def handle_info({:connection_status, profile_id, status}, state) do
    statuses = Map.put(state.connection_statuses, profile_id, status)
    {:noreply, %{state | connection_statuses: statuses}, render?: false}
  end

  def handle_info(:throbber_tick, state) do
    grid = state.datagrid_state

    if grid && grid.loading_more do
      timer = Process.send_after(self(), :throbber_tick, 80)

      {:noreply,
       %{state | throbber_step: rem((state.throbber_step || 0) + 1, 64), throbber_timer: timer}}
    else
      {:noreply, %{state | throbber_timer: nil}, render?: false}
    end
  end

  def handle_info({:table_data_loaded, req_id, profile_id, schema, table_name, result}, state) do
    state =
      if state.table_request_id == req_id and state.selected_table == table_name do
        state = cancel_throbber_timer(state)

        case result do
          {:ok, cols, rows} ->
            has_more = length(rows) == 100
            Strata.DataStore.put_table_cache(profile_id, schema, table_name, cols, rows, has_more)

            cached_pks =
              case Strata.DataStore.get_schema_cache(profile_id, schema, table_name) do
                {:ok, %{primary_keys: pks}} -> pks
                _ -> []
              end

            grid =
              DataGrid.new(cols, rows,
                batch_size: 100,
                has_more: has_more,
                loading_more: false,
                primary_keys: cached_pks
              )

            %{
              state
              | datagrid_state: grid,
                structure_restore_grid: nil,
                status_message: "[DB] Loaded table '#{table_name}' (#{length(rows)} rows)"
            }

          {:error, reason} ->
            msg = if is_binary(reason), do: reason, else: inspect(reason)
            err_grid = DataGrid.new(["error"], [[msg]], has_more: false, loading_more: false)

            %{
              state
              | datagrid_state: err_grid,
                status_message: "❌ Error loading table '#{table_name}': #{msg}"
            }
        end
      else
        state
      end

    {:noreply, state}
  end

  def handle_info({:table_count_loaded, req_id, table_name, {:ok, total_count}}, state) do
    state =
      if state.table_request_id == req_id and state.selected_table == table_name and
           state.datagrid_state != nil and state.datagrid_state.view_mode == :data do
        %{state | datagrid_state: %{state.datagrid_state | total_db_rows: total_count}}
      else
        state
      end

    {:noreply, state}
  end

  def handle_info({:table_count_loaded, _req_id, _table_name, _err}, state) do
    {:noreply, state, render?: false}
  end

  def handle_info(
        {:table_schema_loaded, _req_id, profile_id, schema, table_name, {:ok, schema_info}},
        state
      ) do
    Strata.DataStore.put_schema_cache(profile_id, schema, table_name, schema_info)

    state =
      if state.selected_table == table_name and state.datagrid_state != nil do
        updated_grid = %{state.datagrid_state | primary_keys: schema_info.primary_keys}
        %{state | datagrid_state: updated_grid}
      else
        state
      end

    {:noreply, state, render?: false}
  end

  def handle_info({:table_schema_loaded, _req_id, _pid, _schema, _tbl, _err}, state) do
    {:noreply, state, render?: false}
  end

  def handle_info({:structure_view_loaded, req_id, profile_id, schema, table_name, result}, state) do
    state =
      if state.table_request_id == req_id and state.selected_table == table_name do
        state = cancel_throbber_timer(state)

        case result do
          {:ok, schema_info} ->
            Strata.DataStore.put_schema_cache(profile_id, schema, table_name, schema_info)

            struct_grid =
              DataGrid.new(schema_info.columns, schema_info.rows,
                view_mode: :structure,
                primary_keys: schema_info.primary_keys,
                has_more: false,
                loading_more: false
              )

            restore_grid =
              case state.structure_restore_grid do
                %DataGrid{} = g -> %{g | primary_keys: schema_info.primary_keys}
                other -> other
              end

            %{
              state
              | datagrid_state: struct_grid,
                structure_restore_grid: restore_grid,
                status_message:
                  "Structure view '#{table_name}' (#{length(schema_info.rows)} columns)"
            }

          {:error, reason} ->
            msg = if is_binary(reason), do: reason, else: inspect(reason)
            restored = state.structure_restore_grid || state.datagrid_state

            %{
              state
              | datagrid_state: restored,
                structure_restore_grid: nil,
                status_message: "❌ Schema inspect error: #{msg}"
            }
        end
      else
        state
      end

    {:noreply, state}
  end

  def handle_info({:table_sorted_loaded, req_id, table_name, sort_by, result}, state) do
    state =
      if state.table_request_id == req_id and state.selected_table == table_name do
        state = cancel_throbber_timer(state)
        old_grid = state.datagrid_state
        existing_total_db = old_grid && old_grid.total_db_rows
        existing_pks = (old_grid && old_grid.primary_keys) || []
        {_old_r, old_c} = (old_grid && old_grid.selected_cell) || {0, 0}
        old_col_offset = (old_grid && old_grid.col_offset) || 0
        old_mode = (old_grid && old_grid.mode) || :browsing

        case result do
          {:ok, cols, rows} ->
            has_more = length(rows) == 100
            max_c = max(0, length(cols) - 1)
            kept_c = min(old_c, max_c)
            kept_offset = min(old_col_offset, max_c)

            grid =
              DataGrid.new(cols, rows,
                batch_size: 100,
                has_more: has_more,
                loading_more: false,
                sort_by: sort_by,
                total_db_rows: existing_total_db,
                primary_keys: existing_pks,
                selected_cell: {0, kept_c},
                col_offset: kept_offset,
                mode: old_mode
              )

            sort_desc =
              case sort_by do
                {col, dir} -> "Sorted by #{col} #{String.upcase(to_string(dir))}"
                nil -> "Cleared sort"
              end

            %{state | datagrid_state: grid, status_message: "#{sort_desc} (#{length(rows)} rows)"}

          {:error, reason} ->
            msg = if is_binary(reason), do: reason, else: inspect(reason)
            grid = %{state.datagrid_state | loading_more: false}
            %{state | datagrid_state: grid, status_message: "❌ Sort error: #{msg}"}
        end
      else
        state
      end

    {:noreply, state}
  end

  def handle_info({:commit_finished, _req_id, profile_id, schema, table_name, result}, state) do
    state = cancel_throbber_timer(state)

    state =
      case result do
        {:ok, stmt_count} ->
          Strata.DataStore.invalidate_table_cache(profile_id, schema, table_name)

          state
          |> load_table_async(table_name, refresh: true)
          |> Map.put(:status_message, "✅ Committed #{stmt_count} statement(s) to '#{table_name}'")

        {:error, reason} ->
          msg = if is_binary(reason), do: reason, else: inspect(reason)
          %{state | status_message: "❌ Commit rolled back: #{msg}"}
      end

    {:noreply, state}
  end

  def handle_info({:connection_test_finished, res}, state) do
    state =
      case state.modals do
        [%ConnectionModal{} = cm | rest] ->
          updated_cm =
            case res do
              :ok ->
                %{cm | status: :ok, status_message: "⚡ Connection successful!"}

              {:ok, _} ->
                %{cm | status: :ok, status_message: "⚡ Connection successful!"}

              {:error, reason} ->
                msg = if is_binary(reason), do: reason, else: inspect(reason)
                %{cm | status: :error, status_message: "❌ Connection failed: " <> msg}
            end

          %{state | modals: [updated_cm | rest]}

        _ ->
          state
      end

    {:noreply, state}
  end

  def handle_info({:ssh_test_finished, res}, state) do
    state =
      case state.modals do
        [%SSHModal{} = sm | rest] ->
          updated_sm =
            case res do
              :ok ->
                %{sm | status: :ok, status_message: "⚡ SSH connection successful!"}

              {:ok, _} ->
                %{sm | status: :ok, status_message: "⚡ SSH connection successful!"}

              {:error, reason} ->
                msg = if is_binary(reason), do: reason, else: inspect(reason)
                %{sm | status: :error, status_message: "❌ SSH test failed: " <> msg}
            end

          %{state | modals: [updated_sm | rest]}

        _ ->
          state
      end

    {:noreply, state}
  end

  def handle_info({:filter_query_finished, where_clause, order_by_clause, result}, state) do
    state =
      case result do
        {:ok, %{columns: cols, rows: rows}} ->
          old_grid = state.datagrid_state
          existing_total = old_grid && old_grid.total_db_rows
          existing_pks = (old_grid && old_grid.primary_keys) || []
          existing_sort = old_grid && old_grid.sort_by
          {_old_r, old_c} = (old_grid && old_grid.selected_cell) || {0, 0}
          old_col_offset = (old_grid && old_grid.col_offset) || 0
          old_mode = (old_grid && old_grid.mode) || :browsing
          max_c = max(0, length(cols) - 1)

          grid =
            DataGrid.new(cols, rows,
              has_more: false,
              loading_more: false,
              total_db_rows: existing_total,
              primary_keys: existing_pks,
              sort_by: existing_sort,
              selected_cell: {0, min(old_c, max_c)},
              col_offset: min(old_col_offset, max_c),
              mode: old_mode
            )

          %{
            state
            | datagrid_state: grid,
              status_message:
                "Filter applied (#{length(rows)} rows): #{where_clause} #{order_by_clause}"
          }

        {:error, reason} ->
          msg = if is_binary(reason), do: reason, else: inspect(reason)
          %{state | status_message: "❌ Filter SQL error: #{msg}"}
      end

    {:noreply, state}
  end

  def handle_info({:sql_query_finished, elapsed, profile, ddl?, result}, state) do
    state = apply_sql_query_result(state, elapsed, result)

    state =
      if ddl? and match?({:ok, _}, result) and profile != nil do
        refresh_connection_schema_async(state, profile)
      else
        state
      end

    {:noreply, state}
  end

  def handle_info({:sql_query_finished, elapsed, result}, state) do
    {:noreply, apply_sql_query_result(state, elapsed, result)}
  end

  def handle_info({:table_chunk_loaded, table_name, _offset, result}, state) do
    state =
      if state.active_view == :table_view and state.selected_table == table_name and
           state.datagrid_state do
        grid = state.datagrid_state

        case result do
          {:ok, _cols, new_rows} ->
            has_more = length(new_rows) == (grid.batch_size || 100)
            updated_grid = DataGrid.append_rows(grid, new_rows, has_more)

            if profile = Sidebar.resolve_profile_for_selection(state) do
              Strata.DataStore.append_table_cache(
                profile.id,
                state.selected_schema,
                table_name,
                new_rows,
                has_more
              )
            end

            status_msg =
              "Loaded +#{length(new_rows)} rows for '#{table_name}' (Total: #{length(updated_grid.rows)} rows)"

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

  def handle_info(_msg, state), do: {:noreply, state, render?: false}

  defp safe_list_profiles do
    Strata.ConfigStore.list_profiles()
  catch
    _, _ -> []
  end

  defp start_schema_stream_tasks(state, []), do: %{state | sidebar_nodes: Sidebar.load_nodes()}

  defp start_schema_stream_tasks(state, profiles) do
    caller = self()
    default_expanded? = length(profiles) == 1

    Enum.each(profiles, fn profile ->
      Task.start(fn ->
        node = Strata.SchemaInspector.fetch_tree_nodes(profile, expanded?: default_expanded?)
        send(caller, {:connection_schema_loaded, profile.id, node})
      end)
    end)

    state
  end

  defp refresh_selected_connection_schema_async(state) do
    case Sidebar.resolve_profile_for_selection(state) do
      nil ->
        %{state | status_message: "No database connection selected"}

      profile ->
        refresh_connection_schema_async(state, profile)
    end
  end

  defp refresh_connection_schema_async(state, profile) do
    Strata.DataStore.invalidate_connection_cache(profile.id)
    caller = self()
    profiles = safe_list_profiles()
    default_expanded? = length(profiles) <= 1

    Task.start(fn ->
      node = Strata.SchemaInspector.fetch_tree_nodes(profile, expanded?: default_expanded?)
      send(caller, {:connection_schema_loaded, profile.id, node})
    end)

    %{state | status_message: "⏳ Refreshing schema for '#{profile.name}'..."}
  end

  defp upsert_connection_node(nodes, profile_id, new_node) do
    case Enum.split_with(nodes, &(&1.id == profile_id)) do
      {[], _} ->
        filtered = Enum.reject(nodes, &(&1.id == "no_conn_prompt"))
        filtered ++ [new_node]

      {[existing | _], _rest} ->
        preserved = preserve_tree_expansion(existing, new_node)

        Enum.map(nodes, fn n ->
          if n.id == profile_id, do: preserved, else: n
        end)
    end
  end

  defp preserve_tree_expansion(old_node, new_node) do
    old_loading? =
      case Map.get(old_node, :children, []) do
        [%{id: id} | _] -> String.ends_with?(to_string(id), "_loading")
        _ -> false
      end

    exp? =
      if old_loading?,
        do: Map.get(new_node, :expanded?, true),
        else: Map.get(old_node, :expanded?, Map.get(new_node, :expanded?, true))

    old_children_by_id = Map.new(Map.get(old_node, :children, []), &{&1.id, &1})

    updated_children =
      Enum.map(Map.get(new_node, :children, []), fn child ->
        case Map.get(old_children_by_id, child.id) do
          nil ->
            child

          old_child ->
            %{
              child
              | expanded?: Map.get(old_child, :expanded?, Map.get(child, :expanded?, false))
            }
        end
      end)

    %{new_node | expanded?: exp?, children: updated_children}
  end

  defp apply_sql_query_result(state, elapsed, result) do
    case result do
      {:ok, %{columns: cols, rows: rows}} ->
        grid = DataGrid.new(cols, rows, has_more: false, loading_more: false)

        state
        |> switch_view(:query_view)
        |> Map.put(:datagrid_state, grid)
        |> Map.put(
          :status_message,
          "⚡ Query executed successfully (#{length(rows)} rows in #{elapsed}ms)"
        )

      {:error, reason} ->
        msg = if is_binary(reason), do: reason, else: inspect(reason)
        err_grid = DataGrid.new(["error"], [[msg]], has_more: false, loading_more: false)

        state
        |> switch_view(:query_view)
        |> Map.put(:datagrid_state, err_grid)
        |> Map.put(:status_message, "❌ SQL Error: #{msg}")
    end
  end

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

  @impl true
  def terminate(_reason, state) do
    if Map.get(state, :terminal, false) do
      self_pid = self()

      spawn(fn ->
        ref = Process.monitor(self_pid)

        receive do
          {:DOWN, ^ref, :process, ^self_pid, _reason} ->
            Process.sleep(50)
            System.halt(0)
        after
          2000 ->
            System.halt(0)
        end
      end)
    end

    :ok
  end

  defp map_ex_ratatui_key(code, modifiers) do
    modifiers = modifiers || []
    ctrl? = "control" in modifiers or "Ctrl" in modifiers or "ctrl" in modifiers

    super? =
      "super" in modifiers or "meta" in modifiers or "Super" in modifiers or "Meta" in modifiers

    shift? = "shift" in modifiers or "Shift" in modifiers

    cond do
      ctrl? and code in ["enter", "Enter"] ->
        {:ctrl, "enter"}

      (ctrl? or super?) and is_binary(code) and String.length(code) == 1 ->
        {:ctrl, String.downcase(code)}

      code in ["back_tab", "BackTab"] or (shift? and code in ["tab", "Tab"]) ->
        :shift_tab

      code in ["up", "Up"] ->
        :up

      code in ["down", "Down"] ->
        :down

      code in ["left", "Left"] ->
        :left

      code in ["right", "Right"] ->
        :right

      code in ["tab", "Tab"] ->
        :tab

      code in ["enter", "Enter"] ->
        :enter

      code in ["esc", "escape", "Esc", "Escape"] ->
        :esc

      code in ["backspace", "Backspace"] ->
        :backspace

      code in ["delete", "Delete"] ->
        :delete

      code in ["home", "Home"] ->
        :home

      code in ["end", "End"] ->
        :end

      code in ["page_up", "PageUp", "pageup"] ->
        :page_up

      code in ["page_down", "PageDown", "pagedown"] ->
        :page_down

      code in ["f1", "F1"] ->
        :f1

      code in ["f2", "F2"] ->
        :f2

      code in ["f3", "F3"] ->
        :f3

      code in ["f5", "F5"] ->
        :f5

      code in ["f6", "F6"] ->
        :f6

      is_binary(code) and String.length(code) == 1 ->
        code

      true ->
        :unknown
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

    first_id =
      case List.first(nodes) do
        nil -> nil
        n -> n.id
      end

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
  Non-blocking table selection: serves instantly from ETS DataStore cache on hit,
  auto-focuses DataGrid, or spawns a background Task with request_id guard on miss.
  """
  @spec load_table_async(t(), String.t(), keyword()) :: t()
  def load_table_async(%__MODULE__{} = app, table_name, opts \\ []) when is_binary(table_name) do
    {profile, schema} = Sidebar.resolve_selection_context(app)
    refresh? = Keyword.get(opts, :refresh, false)
    req_id = System.unique_integer([:positive])

    cond do
      is_nil(profile) ->
        grid = DataGrid.new(["info"], [["No database connection configured"]], has_more: false)

        app
        |> switch_view(:table_view)
        |> set_focus(:datagrid)
        |> Map.put(:selected_table, table_name)
        |> Map.put(:selected_schema, schema)
        |> Map.put(:table_request_id, req_id)
        |> Map.put(:datagrid_state, grid)
        |> Map.put(:status_message, "No database connection configured")

      not refresh? and
          match?({:ok, _}, Strata.DataStore.get_table_cache(profile.id, schema, table_name)) ->
        {:ok, entry} = Strata.DataStore.get_table_cache(profile.id, schema, table_name)

        grid =
          DataGrid.new(entry.columns, entry.rows,
            batch_size: 100,
            has_more: entry.has_more,
            loading_more: false
          )

        app
        |> switch_view(:table_view)
        |> set_focus(:datagrid)
        |> Map.put(:selected_table, table_name)
        |> Map.put(:selected_schema, schema)
        |> Map.put(:table_request_id, req_id)
        |> Map.put(:datagrid_state, grid)
        |> Map.put(
          :status_message,
          "[Cache] Loaded table '#{table_name}' (#{length(entry.rows)} rows)"
        )

      true ->
        if refresh? do
          Strata.DataStore.invalidate_table_cache(profile.id, schema, table_name)
        end

        caller = self()

        Task.start(fn ->
          result = Sidebar.fetch_table_chunk(profile, table_name, 0, 100, schema: schema)
          send(caller, {:table_data_loaded, req_id, profile.id, schema, table_name, result})
        end)

        Task.start(fn ->
          count_res = Sidebar.fetch_table_count(profile, table_name, schema: schema)
          send(caller, {:table_count_loaded, req_id, table_name, count_res})
        end)

        if Strata.DataStore.get_schema_cache(profile.id, schema, table_name) == :miss do
          Task.start(fn ->
            schema_res =
              Strata.SchemaInspector.fetch_table_schema(profile, table_name, schema: schema)

            send(
              caller,
              {:table_schema_loaded, req_id, profile.id, schema, table_name, schema_res}
            )
          end)
        end

        loading_grid =
          DataGrid.new(["Status"], [["⏳ Loading '#{table_name}'..."]],
            has_more: false,
            loading_more: true
          )

        app
        |> switch_view(:table_view)
        |> set_focus(:datagrid)
        |> Map.put(:selected_table, table_name)
        |> Map.put(:selected_schema, schema)
        |> Map.put(:table_request_id, req_id)
        |> Map.put(:datagrid_state, loading_grid)
        |> Map.put(:structure_restore_grid, nil)
        |> Map.put(:inline_input_ref, nil)
        |> Map.put(:active_filter, nil)
        |> Map.put(:filter_bar_open, false)
        |> Map.put(:filter_bar_focused, false)
        |> Map.put(:filter_bar_mode, :builder)
        |> Map.put(:filter_bar_focus_part, :value)
        |> Map.put(:filter_bar_col, "* All")
        |> Map.put(:filter_bar_op, :contains)
        |> Map.put(:filter_bar_text, "")
        |> Map.put(:filter_dropdown, nil)
        |> Map.put(:filter_dropdown_idx, 0)
        |> Map.put(:filter_dropdown_search, "")
        |> Map.put(:sort_picker_open, false)
        |> Map.put(:sort_picker_idx, 0)
        |> Map.put(:sort_picker_search, "")
        |> Map.put(:status_message, "⏳ Loading table '#{table_name}'...")
        |> start_throbber_timer()
    end
  end

  defp test_connection_async(%__MODULE__{modals: [%ConnectionModal{} = cm | rest]} = state) do
    profile = ConnectionModal.to_profile(cm)
    caller = self()

    Task.start(fn ->
      res = Strata.ConnectionWorker.test_connection(profile)
      send(caller, {:connection_test_finished, res})
    end)

    updated_cm = %{cm | status: :testing, status_message: "⏳ Testing connection..."}
    %{state | modals: [updated_cm | rest]}
  end

  defp test_connection_async(state), do: state

  defp test_ssh_async(%__MODULE__{modals: [%SSHModal{} = sm | rest]} = state) do
    profile = SSHModal.to_profile(sm)
    caller = self()

    Task.start(fn ->
      res =
        case Strata.SSHTunnel.connect(profile, "127.0.0.1", profile.port || 22) do
          {:ok, _port, pid} ->
            Strata.SSHTunnel.stop(pid)
            :ok

          {:error, reason} ->
            {:error, reason}
        end

      send(caller, {:ssh_test_finished, res})
    end)

    updated_sm = %{sm | status: :testing, status_message: "⏳ Testing SSH connection..."}
    %{state | modals: [updated_sm | rest]}
  end

  defp test_ssh_async(state), do: state

  @doc """
  Invalidates cache and reloads the currently selected table.
  """
  @spec refresh_active_table(t()) :: t()
  def refresh_active_table(%__MODULE__{active_view: :table_view, selected_table: tbl} = app)
      when is_binary(tbl) do
    load_table_async(app, tbl, refresh: true)
  end

  def refresh_active_table(app), do: app

  @doc """
  Toggles Table View between `:data` rows and `:structure` schema metadata.
  """
  @spec toggle_structure_view(t()) :: t()
  def toggle_structure_view(%__MODULE__{active_view: :table_view, selected_table: tbl} = app)
      when is_binary(tbl) do
    grid = app.datagrid_state || DataGrid.new()

    if grid.view_mode == :structure do
      restored = app.structure_restore_grid || DataGrid.new()

      %{
        app
        | datagrid_state: %{restored | view_mode: :data},
          structure_restore_grid: nil,
          inline_input_ref: nil,
          status_message: "Data view '#{tbl}'"
      }
    else
      {profile, schema} = Sidebar.resolve_selection_context(app)
      schema = schema || app.selected_schema

      if profile do
        case Strata.DataStore.get_schema_cache(profile.id, schema, tbl) do
          {:ok, schema_info} ->
            struct_grid =
              DataGrid.new(schema_info.columns, schema_info.rows,
                view_mode: :structure,
                primary_keys: schema_info.primary_keys,
                has_more: false,
                loading_more: false
              )

            %{
              app
              | datagrid_state: struct_grid,
                structure_restore_grid: %{grid | primary_keys: schema_info.primary_keys},
                inline_input_ref: nil,
                status_message: "Structure view '#{tbl}' (#{length(schema_info.rows)} columns)"
            }

          :miss ->
            req_id = System.unique_integer([:positive])
            caller = self()

            Task.start(fn ->
              res = Strata.SchemaInspector.fetch_table_schema(profile, tbl, schema: schema)
              send(caller, {:structure_view_loaded, req_id, profile.id, schema, tbl, res})
            end)

            loading_grid =
              DataGrid.new(["Status"], [["⏳ Inspecting '#{tbl}'..."]],
                view_mode: :structure,
                has_more: false,
                loading_more: true
              )

            %{
              app
              | table_request_id: req_id,
                datagrid_state: loading_grid,
                structure_restore_grid: grid,
                inline_input_ref: nil,
                status_message: "⏳ Inspecting structure of '#{tbl}'..."
            }
            |> start_throbber_timer()
        end
      else
        %{app | status_message: "No active connection for structure view"}
      end
    end
  end

  def toggle_structure_view(app), do: app

  @doc """
  Sorts the active table or grid by column index `col_idx` (cycling ASC -> DESC -> none).
  Re-queries the DB with `ORDER BY` when viewing a clean live table, or sorts in memory
  for query results, structure view, or when staged edits are present.
  """
  @spec sort_active_table_by_col(t(), non_neg_integer()) :: t()
  def sort_active_table_by_col(%__MODULE__{} = app, col_idx) do
    grid = app.datagrid_state || DataGrid.new()

    cond do
      DataGrid.dirty_count(grid) > 0 ->
        %{app | status_message: "⚠️ Commit (Ctrl+S) or Revert (Ctrl+Z) changes before sorting"}

      true ->
        case Enum.at(grid.columns, col_idx) do
          nil ->
            app

          col_name ->
            col_str = to_string(col_name)
            sorted_grid = DataGrid.cycle_sort(grid, col_str)
            {profile, schema} = Sidebar.resolve_selection_context(app)
            schema = schema || app.selected_schema

            if app.active_view == :table_view and grid.view_mode == :data and
                 is_binary(app.selected_table) and
                 profile != nil do
              req_id = System.unique_integer([:positive])
              caller = self()
              tbl = app.selected_table
              sort_by = sorted_grid.sort_by
              active_filter = app.active_filter
              sample_row = List.first(grid.rows) || []

              Task.start(fn ->
                res =
                  if is_map(active_filter) do
                    qualified = Sidebar.qualify_table(profile.driver, tbl, schema)

                    case Strata.QueryBuilder.build_filter_select(
                           profile.driver,
                           qualified,
                           grid.columns,
                           active_filter,
                           order_by: sort_by,
                           sample_row: sample_row
                         ) do
                      {:ok, {sql, params}} ->
                        case Strata.ConnectionWorker.execute_query_for_profile(
                               profile,
                               sql,
                               params
                             ) do
                          {:ok, %{columns: cols, rows: rows}} -> {:ok, cols, rows}
                          {:error, reason} -> {:error, reason}
                        end

                      {:error, reason} ->
                        {:error, reason}
                    end
                  else
                    Sidebar.fetch_table_chunk(profile, tbl, 0, 100,
                      schema: schema,
                      order_by: sort_by
                    )
                  end

                send(caller, {:table_sorted_loaded, req_id, tbl, sort_by, res})
              end)

              %{
                app
                | table_request_id: req_id,
                  datagrid_state: %{sorted_grid | loading_more: true},
                  status_message: "⏳ Sorting '#{tbl}' by #{col_str}..."
              }
              |> start_throbber_timer()
            else
              in_mem_grid = DataGrid.sort_rows_in_memory(sorted_grid)

              sort_msg =
                case in_mem_grid.sort_by do
                  {c, dir} -> "Sorted by #{c} #{String.upcase(to_string(dir))}"
                  nil -> "Cleared sort"
                end

              %{app | datagrid_state: in_mem_grid, status_message: sort_msg}
            end
        end
    end
  end

  @doc """
  Opens FilterExportModal in `:filter` mode, preserving any active filter or pre-filling
  the selected column in Select mode, and passing column hints for easy filtering.
  """
  @spec open_filter_modal(t()) :: t()
  def open_filter_modal(%__MODULE__{datagrid_state: %DataGrid{} = grid} = app) do
    {_r, c} = grid.selected_cell
    col_name = Enum.at(grid.columns, c)

    opts =
      case app.active_filter do
        %{where: w, order_by: o, limit: l} ->
          [where: w, order_by: o, limit: l, columns: grid.columns, selected_column: col_name]

        _ ->
          base = [columns: grid.columns, selected_column: col_name]

          if grid.mode == :selecting and grid.view_mode == :data and is_binary(col_name) do
            Keyword.put(base, :where, "#{col_name} = ")
          else
            base
          end
      end

    push_modal(app, FilterExportModal.new(:filter, opts))
  end

  def open_filter_modal(app), do: push_modal(app, FilterExportModal.new(:filter))

  @doc """
  Opens and focuses the Visual Smart Filter Bar (`* All` Quick Search, `[Col ▾] [Op ▾] [Val]`,
  or Raw SQL mode). Pass `all_columns: true` (e.g. from `/`) to start directly in Quick Search.
  """
  @spec open_filter_bar(t(), keyword()) :: t()
  def open_filter_bar(app, opts \\ [])

  def open_filter_bar(%__MODULE__{datagrid_state: %DataGrid{} = grid} = app, opts) do
    all_cols? = Keyword.get(opts, :all_columns, false)
    {_r, c} = grid.selected_cell
    selected_col = Enum.at(grid.columns, c)

    {mode, col, op, initial_text} =
      cond do
        all_cols? ->
          {:builder, "* All", :contains, ""}

        is_map(app.active_filter) ->
          af = app.active_filter

          {
            Map.get(af, :mode, :builder),
            Map.get(af, :column, "* All"),
            Map.get(af, :op, :contains),
            Map.get(af, :value) || Map.get(af, :raw_where) || Map.get(af, :where) || ""
          }

        grid.mode == :selecting and grid.view_mode == :data and is_binary(selected_col) ->
          {:builder, selected_col, :contains, app.filter_bar_text || ""}

        true ->
          {app.filter_bar_mode || :builder, app.filter_bar_col || "* All",
           app.filter_bar_op || :contains, app.filter_bar_text || ""}
      end

    ref = app.filter_bar_ref || ExRatatui.text_input_new()
    ExRatatui.text_input_set_value(ref, to_string(initial_text))

    focus_part =
      if mode == :builder and op in [:is_null, :is_not_null], do: :op, else: :value

    %{
      app
      | focus: :datagrid,
        filter_bar_open: true,
        filter_bar_focused: true,
        filter_bar_mode: mode,
        filter_bar_focus_part: focus_part,
        filter_bar_col: col,
        filter_bar_op: op,
        filter_bar_ref: ref,
        filter_bar_text: to_string(initial_text),
        filter_history_idx: nil,
        filter_history_draft: nil,
        status_message: "🔍 Filter: type value & Enter · Tab Col/Op · Ctrl+R SQL · Ctrl+L Reset"
    }
  end

  def open_filter_bar(app, _opts), do: app

  @doc """
  One-keystroke filter by the currently selected cell value (`Shift+F` in Select mode).
  Falls back to opening the Filter Bar when called from Browsing mode.
  """
  @spec filter_by_selected_cell(t()) :: t()
  def filter_by_selected_cell(
        %__MODULE__{datagrid_state: %DataGrid{mode: :selecting, view_mode: :data} = grid} = app
      )
      when grid.columns != [] do
    {r, c} = grid.selected_cell
    eff_rows = DataGrid.effective_rows(grid)
    col_name = Enum.at(grid.columns, c)
    raw_val = eff_rows |> Enum.at(r, []) |> Enum.at(c, nil)

    if is_binary(col_name) do
      {op, val_str} =
        if is_nil(raw_val) do
          {:is_null, ""}
        else
          {:=, Strata.Formatter.sanitize_cell(raw_val)}
        end

      ref = app.filter_bar_ref || ExRatatui.text_input_new()
      ExRatatui.text_input_set_value(ref, val_str)

      app
      |> Map.put(:filter_bar_open, true)
      |> Map.put(:filter_bar_focused, false)
      |> Map.put(:filter_bar_mode, :builder)
      |> Map.put(:filter_bar_focus_part, :value)
      |> Map.put(:filter_bar_col, col_name)
      |> Map.put(:filter_bar_op, op)
      |> Map.put(:filter_bar_ref, ref)
      |> Map.put(:filter_bar_text, val_str)
      |> apply_smart_filter()
    else
      open_filter_bar(app)
    end
  end

  def filter_by_selected_cell(app), do: open_filter_bar(app)

  @doc """
  Handles key events when the Visual Smart Filter Bar has focus.
  """
  @spec handle_filter_bar_key(t(), term()) :: t()
  def handle_filter_bar_key(%__MODULE__{filter_dropdown: kind} = app, key)
      when kind in [:column, :op] do
    handle_filter_dropdown_key(app, key)
  end

  def handle_filter_bar_key(%__MODULE__{} = app, key) do
    case key do
      {:ctrl, "l"} ->
        clear_table_filter(app)

      {:ctrl, "r"} ->
        next_mode = if app.filter_bar_mode == :raw, do: :builder, else: :raw
        %{app | filter_bar_mode: next_mode, filter_bar_focus_part: :value, filter_dropdown: nil}

      :tab ->
        cycle_filter_part(app, 1)

      :shift_tab ->
        cycle_filter_part(app, -1)

      {:ctrl, "v"} ->
        case Strata.Clipboard.paste() do
          {:ok, ""} -> app
          {:ok, text} -> paste_text(app, text)
          {:error, _} -> %{app | status_message: "📋 Paste failed (no OS clipboard tool)"}
        end

      :esc ->
        if String.trim(app.filter_bar_text || "") == "" and is_nil(app.active_filter) do
          %{app | filter_bar_open: false, filter_bar_focused: false, filter_dropdown: nil}
        else
          %{app | filter_bar_focused: false, filter_dropdown: nil}
        end

      other ->
        cond do
          app.filter_bar_mode == :builder and app.filter_bar_focus_part == :column ->
            handle_filter_column_key(app, other)

          app.filter_bar_mode == :builder and app.filter_bar_focus_part == :op ->
            handle_filter_op_key(app, other)

          true ->
            handle_filter_value_key(app, other)
        end
    end
  end

  defp open_filter_dropdown(app, kind) when kind in [:column, :op] do
    grid = app.datagrid_state || DataGrid.new()

    idx =
      case kind do
        :column ->
          cols = ["* All" | grid.columns || []]
          Enum.find_index(cols, &(&1 == app.filter_bar_col)) || 0

        :op ->
          ops = Strata.QueryBuilder.filter_operators()
          Enum.find_index(ops, &(&1 == app.filter_bar_op)) || 0
      end

    %{
      app
      | filter_bar_open: true,
        filter_bar_focused: true,
        filter_bar_mode: :builder,
        filter_bar_focus_part: kind,
        filter_dropdown: kind,
        filter_dropdown_idx: idx,
        filter_dropdown_search: ""
    }
  end

  defp handle_filter_dropdown_key(app, key) do
    layout = Renderer.layout(app.window_size, app.active_view)
    dd = Renderer.filter_dropdown_data(app, layout.datagrid)
    items = (dd && dd.items) || []
    max_idx = max(0, length(items) - 1)

    case key do
      :esc ->
        %{app | filter_dropdown: nil, filter_dropdown_search: ""}

      :tab ->
        %{app | filter_dropdown: nil, filter_dropdown_search: ""}
        |> cycle_filter_part(1)

      :shift_tab ->
        %{app | filter_dropdown: nil, filter_dropdown_search: ""}
        |> cycle_filter_part(-1)

      :up ->
        next = if app.filter_dropdown_idx <= 0, do: max_idx, else: app.filter_dropdown_idx - 1
        %{app | filter_dropdown_idx: next}

      :down ->
        next = if app.filter_dropdown_idx >= max_idx, do: 0, else: app.filter_dropdown_idx + 1
        %{app | filter_dropdown_idx: next}

      :home ->
        %{app | filter_dropdown_idx: 0}

      :end ->
        %{app | filter_dropdown_idx: max_idx}

      :backspace when app.filter_dropdown == :column ->
        s = app.filter_dropdown_search || ""
        new_s = String.slice(s, 0, max(0, String.length(s) - 1))
        %{app | filter_dropdown_search: new_s, filter_dropdown_idx: 0}

      k when is_binary(k) and app.filter_dropdown == :column ->
        if String.length(k) == 1 do
          %{
            app
            | filter_dropdown_search: (app.filter_dropdown_search || "") <> k,
              filter_dropdown_idx: 0
          }
        else
          app
        end

      k when k in [:enter, :space] ->
        select_filter_dropdown_item(app, Enum.at(items, min(app.filter_dropdown_idx, max_idx)))

      {:ctrl, "l"} ->
        clear_table_filter(app)

      _ ->
        app
    end
  end

  defp select_filter_dropdown_item(app, nil) do
    %{app | filter_dropdown: nil, filter_dropdown_search: ""}
  end

  defp select_filter_dropdown_item(%{filter_dropdown: :column} = app, %{value: val}) do
    %{
      app
      | filter_bar_col: val,
        filter_dropdown: nil,
        filter_dropdown_search: "",
        filter_bar_focus_part:
          if(app.filter_bar_op in [:is_null, :is_not_null], do: :op, else: :value)
    }
  end

  defp select_filter_dropdown_item(%{filter_dropdown: :op} = app, %{value: op}) do
    updated = %{app | filter_bar_op: op, filter_dropdown: nil, filter_dropdown_search: ""}

    if op in [:is_null, :is_not_null] do
      apply_smart_filter(%{updated | filter_bar_focused: false, filter_bar_focus_part: :op})
    else
      %{updated | filter_bar_focus_part: :value}
    end
  end

  defp cycle_filter_part(%{filter_bar_mode: :raw} = app, _delta) do
    %{
      app
      | filter_bar_focused: false,
        filter_dropdown: nil,
        status_message: "Grid focus (press [f] to edit filter)"
    }
  end

  defp cycle_filter_part(app, delta) do
    parts =
      if app.filter_bar_op in [:is_null, :is_not_null] do
        [:column, :op]
      else
        [:column, :op, :value]
      end

    idx = Enum.find_index(parts, &(&1 == app.filter_bar_focus_part)) || 0
    next = Enum.at(parts, rem(idx + delta + length(parts), length(parts)))
    %{app | filter_bar_focus_part: next}
  end

  defp handle_filter_column_key(app, key) do
    cols = ["* All" | (app.datagrid_state && app.datagrid_state.columns) || []]

    case key do
      :left ->
        %{app | filter_bar_col: cycle_list_item(cols, app.filter_bar_col, -1)}

      :right ->
        %{app | filter_bar_col: cycle_list_item(cols, app.filter_bar_col, 1)}

      k when k in [:down, :up, :enter, :space] ->
        open_filter_dropdown(app, :column)

      ch when is_binary(ch) ->
        if String.length(ch) == 1 do
          open_filter_dropdown(app, :column)
          |> Map.put(:filter_dropdown_search, ch)
          |> Map.put(:filter_dropdown_idx, 0)
        else
          app
        end

      _ ->
        app
    end
  end

  defp handle_filter_op_key(app, key) do
    ops = Strata.QueryBuilder.filter_operators()

    case key do
      :left ->
        %{app | filter_bar_op: cycle_list_item(ops, app.filter_bar_op, -1)}

      :right ->
        %{app | filter_bar_op: cycle_list_item(ops, app.filter_bar_op, 1)}

      k when k in [:down, :up, :enter, :space] ->
        open_filter_dropdown(app, :op)

      _ ->
        app
    end
  end

  defp handle_filter_value_key(app, key) do
    case key do
      :enter ->
        raw =
          if app.filter_bar_ref do
            ExRatatui.text_input_get_value(app.filter_bar_ref)
          else
            app.filter_bar_text || ""
          end

        trimmed = String.trim(raw)

        if trimmed == "" and
             (app.filter_bar_mode == :raw or app.filter_bar_op not in [:is_null, :is_not_null]) do
          clear_table_filter(app)
        else
          app
          |> Map.put(:filter_bar_text, raw)
          |> Map.put(:filter_bar_focused, false)
          |> apply_smart_filter()
        end

      :down ->
        if is_integer(app.filter_history_idx) do
          step_filter_history(app, -1)
        else
          %{
            app
            | filter_bar_focused: false,
              status_message: "Grid focus (press [f] to edit filter)"
          }
        end

      :up ->
        step_filter_history(app, 1)

      k when k in [{:ctrl, "u"}, {:ctrl, "k"}] ->
        if app.filter_bar_ref, do: ExRatatui.text_input_set_value(app.filter_bar_ref, "")
        %{app | filter_bar_text: "", filter_history_idx: nil}

      other_key ->
        if app.filter_bar_ref do
          if nif_key = map_key_to_text_input(other_key) do
            ExRatatui.text_input_handle_key(app.filter_bar_ref, nif_key)
          end

          new_text = ExRatatui.text_input_get_value(app.filter_bar_ref)
          %{app | filter_bar_text: new_text, filter_history_idx: nil}
        else
          app
        end
    end
  end

  defp step_filter_history(app, delta) do
    table_key = app.selected_table || "__query__"
    entries = Map.get(app.filter_history || %{}, table_key, [])

    if entries == [] do
      app
    else
      draft =
        app.filter_history_draft ||
          %{
            mode: app.filter_bar_mode || :builder,
            column: app.filter_bar_col || "* All",
            op: app.filter_bar_op || :contains,
            text: app.filter_bar_text || ""
          }

      new_idx =
        case {app.filter_history_idx, delta} do
          {nil, 1} -> 0
          {nil, -1} -> nil
          {i, 1} -> min(length(entries) - 1, i + 1)
          {i, -1} -> if(i <= 0, do: nil, else: i - 1)
        end

      case new_idx do
        nil ->
          if app.filter_bar_ref,
            do: ExRatatui.text_input_set_value(app.filter_bar_ref, draft.text)

          %{
            app
            | filter_history_idx: nil,
              filter_history_draft: nil,
              filter_bar_mode: draft.mode,
              filter_bar_col: draft.column,
              filter_bar_op: draft.op,
              filter_bar_text: draft.text
          }

        idx ->
          entry = Enum.at(entries, idx)

          if app.filter_bar_ref,
            do: ExRatatui.text_input_set_value(app.filter_bar_ref, entry.text)

          %{
            app
            | filter_history_idx: idx,
              filter_history_draft: draft,
              filter_bar_mode: entry.mode,
              filter_bar_col: entry.column,
              filter_bar_op: entry.op,
              filter_bar_text: entry.text
          }
      end
    end
  end

  defp cycle_list_item(list, current, delta) do
    idx = Enum.find_index(list, &(&1 == current)) || 0
    cnt = length(list)
    Enum.at(list, rem(idx + delta + cnt, cnt))
  end

  defp apply_smart_filter(app) do
    grid = app.datagrid_state || DataGrid.new()
    mode = app.filter_bar_mode || :builder
    col = app.filter_bar_col || "* All"
    op = app.filter_bar_op || :contains
    val = app.filter_bar_text || ""

    filter_spec =
      if mode == :raw do
        %{mode: :raw, raw_where: val, summary: val}
      else
        op_lbl = Strata.QueryBuilder.operator_label(op)

        summary =
          if op in [:is_null, :is_not_null],
            do: "#{col} #{op_lbl}",
            else: "#{col} #{op_lbl} #{val}"

        %{mode: :builder, column: col, op: op, value: val, summary: summary}
      end

    table_name = app.selected_table
    {profile, schema} = Sidebar.resolve_selection_context(app)
    schema = schema || app.selected_schema

    app =
      app
      |> Map.put(:active_filter, filter_spec)
      |> push_filter_history(filter_spec)

    if is_binary(table_name) and profile != nil do
      qualified = Sidebar.qualify_table(profile.driver, table_name, schema)
      sample_row = List.first(grid.rows) || []

      case Strata.QueryBuilder.build_filter_select(
             profile.driver,
             qualified,
             grid.columns,
             filter_spec,
             order_by: grid.sort_by,
             sample_row: sample_row
           ) do
        {:ok, {sql, params}} ->
          caller = self()

          Task.start(fn ->
            res = Strata.ConnectionWorker.execute_query_for_profile(profile, sql, params)
            send(caller, {:filter_query_finished, filter_spec.summary, "", res})
          end)

          %{app | status_message: "⏳ Filtering: #{filter_spec.summary}..."}

        {:error, reason} ->
          %{app | status_message: "❌ Filter error: #{inspect(reason)}"}
      end
    else
      %{app | status_message: "Filter applied: #{filter_spec.summary}"}
    end
  end

  defp push_filter_history(app, filter_spec) do
    text = String.trim(to_string(filter_spec[:value] || filter_spec[:raw_where] || ""))
    op = filter_spec[:op] || :contains

    if text == "" and op not in [:is_null, :is_not_null] do
      app
    else
      table_key = app.selected_table || "__query__"

      entry = %{
        mode: filter_spec.mode,
        column: filter_spec[:column] || "* All",
        op: op,
        text: text
      }

      existing = Map.get(app.filter_history || %{}, table_key, [])
      updated = [entry | Enum.reject(existing, &(&1 == entry))] |> Enum.take(10)

      %{
        app
        | filter_history: Map.put(app.filter_history || %{}, table_key, updated),
          filter_history_idx: nil
      }
    end
  end

  @doc """
  Clears any active table filter and closes the inline filter bar.
  Only reloads the table from the database when an active filter was actually applied.
  """
  @spec clear_table_filter(t()) :: t()
  def clear_table_filter(%__MODULE__{} = app) do
    had_active_filter? = not is_nil(app.active_filter)
    if app.filter_bar_ref, do: ExRatatui.text_input_set_value(app.filter_bar_ref, "")

    base = %{
      app
      | active_filter: nil,
        filter_bar_open: false,
        filter_bar_focused: false,
        filter_bar_mode: :builder,
        filter_bar_focus_part: :value,
        filter_bar_col: "* All",
        filter_bar_op: :contains,
        filter_bar_text: "",
        filter_history_idx: nil,
        filter_history_draft: nil,
        filter_dropdown: nil,
        filter_dropdown_idx: 0,
        filter_dropdown_search: ""
    }

    if had_active_filter? and app.active_view == :table_view and is_binary(app.selected_table) do
      base
      |> refresh_active_table()
      |> Map.put(:status_message, "Filter cleared — showing full table")
    else
      %{base | status_message: "Filter bar closed"}
    end
  end

  @doc """
  Toggles the Right Inspector Drawer (`inspector_open`).
  """
  @spec toggle_inspector(t()) :: t()
  def toggle_inspector(%__MODULE__{inspector_open: open?} = app) do
    %{
      app
      | inspector_open: not open?,
        focus: :datagrid,
        inspector_value_scroll: 0,
        inspector_summary_scroll: 0
    }
  end

  @doc """
  Opens the Right Inspector Drawer and keeps it live-synced with the selected cell.
  """
  @spec open_inspector(t()) :: t()
  def open_inspector(%__MODULE__{} = app) do
    %{
      app
      | inspector_open: true,
        focus: :datagrid,
        inspector_value_scroll: 0,
        inspector_summary_scroll: 0
    }
  end

  @doc """
  Dismisses open grid drawers/bars cleanly on `Esc` from browsing mode.
  """
  @spec dismiss_grid_overlays(t()) :: t()
  def dismiss_grid_overlays(%__MODULE__{inspector_open: true} = app),
    do: %{app | inspector_open: false}

  def dismiss_grid_overlays(%__MODULE__{filter_bar_open: true} = app),
    do: %{app | filter_bar_open: false, filter_bar_focused: false, filter_dropdown: nil}

  def dismiss_grid_overlays(%__MODULE__{sort_picker_open: true} = app),
    do: %{app | sort_picker_open: false, sort_picker_search: ""}

  def dismiss_grid_overlays(app), do: app

  @doc """
  Scrolls the active Inspector panel (`:value` or `:summary`) by `delta` lines, clamped to content bounds.
  """
  @spec scroll_inspector(t(), :value | :summary, integer()) :: t()
  def scroll_inspector(%__MODULE__{inspector_open: true} = app, section, delta)
      when section in [:value, :summary] and is_integer(delta) do
    layout = Renderer.layout(app.window_size, app.active_view)
    %{inspector_area: i_area} = Renderer.datagrid_areas(layout.datagrid, app)

    if i_area do
      grid = app.datagrid_state || DataGrid.new()
      data = Renderer.inspector_data(app, grid, i_area)

      case section do
        :value ->
          curr = app.inspector_value_scroll || 0
          next = max(0, min(data.max_value_scroll, curr + delta))
          %{app | inspector_value_scroll: next}

        :summary ->
          curr = app.inspector_summary_scroll || 0
          next = max(0, min(data.max_summary_scroll, curr + delta))
          %{app | inspector_summary_scroll: next}
      end
    else
      app
    end
  end

  def scroll_inspector(app, _section, _delta), do: app

  @doc """
  Cycles Inspector display format (`:auto` -> `:text` -> `:raw` -> `:auto`).
  """
  @spec cycle_inspector_format(t()) :: t()
  def cycle_inspector_format(%__MODULE__{} = app) do
    next_fmt =
      case app.inspector_format do
        :auto -> :text
        :text -> :raw
        _ -> :auto
      end

    %{app | inspector_format: next_fmt, inspector_value_scroll: 0}
  end

  @doc """
  Opens the floating Sort Column Picker in Browsing mode (or directly sorts if no columns).
  """
  @spec open_sort_picker(t()) :: t()
  def open_sort_picker(%__MODULE__{datagrid_state: %DataGrid{columns: cols} = grid} = app)
      when cols != [] do
    idx =
      case grid.sort_by do
        {col, _dir} -> Enum.find_index(cols, &(to_string(&1) == col)) || 0
        _ -> 0
      end

    %{
      app
      | focus: :datagrid,
        sort_picker_open: true,
        sort_picker_idx: idx,
        sort_picker_search: "",
        filter_dropdown: nil,
        status_message: "↕ Pick column to sort (↑/↓ Enter · type to search · Esc close)"
    }
  end

  def open_sort_picker(app), do: app

  @doc """
  Handles keyboard events inside the Sort Column Picker dropdown.
  """
  @spec handle_sort_picker_key(t(), term()) :: t()
  def handle_sort_picker_key(%__MODULE__{} = app, key) do
    layout = Renderer.layout(app.window_size, app.active_view)
    sp = Renderer.sort_picker_data(app, layout.datagrid)
    items = (sp && sp.items) || []
    max_idx = max(0, length(items) - 1)

    case key do
      :esc ->
        %{app | sort_picker_open: false, sort_picker_search: ""}

      :up ->
        next = if app.sort_picker_idx <= 0, do: max_idx, else: app.sort_picker_idx - 1
        %{app | sort_picker_idx: next}

      :down ->
        next = if app.sort_picker_idx >= max_idx, do: 0, else: app.sort_picker_idx + 1
        %{app | sort_picker_idx: next}

      :home ->
        %{app | sort_picker_idx: 0}

      :end ->
        %{app | sort_picker_idx: max_idx}

      :backspace ->
        s = app.sort_picker_search || ""
        new_s = String.slice(s, 0, max(0, String.length(s) - 1))
        %{app | sort_picker_search: new_s, sort_picker_idx: 0}

      k when is_binary(k) ->
        if String.length(k) == 1 do
          %{app | sort_picker_search: (app.sort_picker_search || "") <> k, sort_picker_idx: 0}
        else
          app
        end

      k when k in [:enter, :space] ->
        select_sort_picker_item(app, Enum.at(items, min(app.sort_picker_idx, max_idx)))

      _ ->
        app
    end
  end

  defp select_sort_picker_item(app, nil) do
    %{app | sort_picker_open: false, sort_picker_search: ""}
  end

  defp select_sort_picker_item(app, %{kind: :clear}) do
    app
    |> Map.put(:sort_picker_open, false)
    |> Map.put(:sort_picker_search, "")
    |> execute_actions_modal_item(:clear_sort)
  end

  defp select_sort_picker_item(app, %{kind: :column, col_idx: col_idx})
       when is_integer(col_idx) do
    app
    |> Map.put(:sort_picker_open, false)
    |> Map.put(:sort_picker_search, "")
    |> sort_active_table_by_col(col_idx)
  end

  @doc """
  Pastes text into the currently active input target (inline cell editor, filter bar,
  modal text field, SQL editor, or selected grid cell).
  """
  @spec paste_text(t(), String.t()) :: t()
  def paste_text(app, text) when is_binary(text) do
    cond do
      text == "" ->
        app

      match?(%DataGrid{editing_cell: {_r, _c}}, app.datagrid_state) and
          not is_nil(app.inline_input_ref) ->
        clean_inline_paste(text)
        |> String.graphemes()
        |> Enum.each(&ExRatatui.text_input_handle_key(app.inline_input_ref, &1))

        app

      app.filter_bar_open and app.filter_bar_focused ->
        clean = clean_inline_paste(text)

        if app.filter_bar_ref do
          clean
          |> String.graphemes()
          |> Enum.each(&ExRatatui.text_input_handle_key(app.filter_bar_ref, &1))

          %{
            app
            | filter_bar_text: ExRatatui.text_input_get_value(app.filter_bar_ref),
              filter_history_idx: nil
          }
        else
          %{app | filter_bar_text: (app.filter_bar_text || "") <> clean, filter_history_idx: nil}
        end

      app.modals != [] ->
        handle_key(app, clean_inline_paste(text))

      app.focus == :editor ->
        SQLEditor.handle_key(app, {:paste, text})

      app.focus == :datagrid and
        match?(%DataGrid{mode: :selecting, view_mode: :data}, app.datagrid_state) and
          app.datagrid_state.columns != [] ->
        grid = app.datagrid_state
        {r, c} = grid.selected_cell
        orig_val = grid.rows |> Enum.at(r, []) |> Enum.at(c, nil)
        clean = String.replace(text, ~r/[\r\n]+$/, "")
        coerced = Strata.QueryBuilder.coerce_value(clean, orig_val)
        updated_grid = DataGrid.stage_cell_edit(grid, r, c, coerced)
        col_name = Enum.at(grid.columns, c, "Cell")

        %{
          app
          | datagrid_state: updated_grid,
            status_message:
              "📋 Pasted into #{col_name} (#{DataGrid.dirty_count(updated_grid)} pending · Ctrl+S commit)"
        }

      true ->
        app
    end
  end

  def paste_text(app, _), do: app

  defp clean_inline_paste(text) do
    text
    |> String.replace(~r/^[\r\n]+|[\r\n]+$/, "")
    |> String.replace(~r/[\r\n]+/, " ")
  end

  @doc """
  Starts inline editing of the currently selected cell using ExRatatui.Widgets.TextInput.
  """
  @spec start_inline_edit(t()) :: t()
  def start_inline_edit(%__MODULE__{datagrid_state: %DataGrid{columns: cols} = grid} = app)
      when cols != [] do
    {r, c} = grid.selected_cell
    eff_rows = DataGrid.effective_rows(grid)

    if r >= 0 and r < length(eff_rows) and c >= 0 and c < length(cols) do
      raw_val = eff_rows |> Enum.at(r, []) |> Enum.at(c, nil)

      initial_text =
        cond do
          is_nil(raw_val) -> ""
          is_binary(raw_val) -> String.replace(raw_val, ~r/[\r\n]+/, " ")
          true -> Strata.Formatter.sanitize_cell(raw_val)
        end

      ref = ExRatatui.text_input_new()
      ExRatatui.text_input_set_value(ref, initial_text)

      col_name = Enum.at(cols, c, "Cell")

      %{
        app
        | datagrid_state: %{grid | mode: :selecting, editing_cell: {r, c}},
          inline_input_ref: ref,
          status_message:
            "Editing #{col_name} (row #{r + 1}) · Enter stage · Ctrl+N NULL · Esc cancel"
      }
    else
      app
    end
  end

  def start_inline_edit(app), do: app

  @doc """
  Handles keystrokes while inline cell editing (`grid.editing_cell`) is active.
  """
  @spec handle_inline_edit_key(t(), term()) :: t()
  def handle_inline_edit_key(
        %__MODULE__{datagrid_state: %DataGrid{editing_cell: {r, c}} = grid} = app,
        key
      ) do
    case key do
      :esc ->
        %{
          app
          | datagrid_state: %{grid | editing_cell: nil},
            inline_input_ref: nil,
            status_message: "Cancelled cell edit"
        }

      {:ctrl, "n"} ->
        updated_grid = DataGrid.stage_cell_edit(grid, r, c, nil)

        %{
          app
          | datagrid_state: updated_grid,
            inline_input_ref: nil,
            status_message:
              "Staged NULL (#{DataGrid.dirty_count(updated_grid)} pending · Ctrl+S commit)"
        }

      {:ctrl, "v"} ->
        case Strata.Clipboard.paste() do
          {:ok, ""} -> app
          {:ok, text} -> paste_text(app, text)
          {:error, _} -> %{app | status_message: "📋 Paste failed (no OS clipboard tool)"}
        end

      :enter ->
        raw_input =
          if app.inline_input_ref do
            ExRatatui.text_input_get_value(app.inline_input_ref)
          else
            ""
          end

        orig_val = grid.rows |> Enum.at(r, []) |> Enum.at(c, nil)
        coerced = Strata.QueryBuilder.coerce_value(raw_input, orig_val)
        updated_grid = DataGrid.stage_cell_edit(grid, r, c, coerced)

        %{
          app
          | datagrid_state: updated_grid,
            inline_input_ref: nil,
            status_message:
              "Staged change (#{DataGrid.dirty_count(updated_grid)} pending · Ctrl+S commit · Ctrl+Z revert)"
        }

      other_key ->
        if app.inline_input_ref do
          if nif_key = map_key_to_text_input(other_key) do
            ExRatatui.text_input_handle_key(app.inline_input_ref, nif_key)
          end
        end

        app
    end
  end

  def handle_inline_edit_key(app, _key), do: app

  defp map_key_to_text_input(:backspace), do: "backspace"
  defp map_key_to_text_input(:delete), do: "delete"
  defp map_key_to_text_input(:left), do: "left"
  defp map_key_to_text_input(:right), do: "right"
  defp map_key_to_text_input(:home), do: "home"
  defp map_key_to_text_input(:end), do: "end"
  defp map_key_to_text_input(:space), do: " "

  defp map_key_to_text_input(key) when is_binary(key) do
    if String.length(key) == 1, do: key, else: nil
  end

  defp map_key_to_text_input(_), do: nil

  @doc """
  Compiles and asynchronously commits all staged cell edits, inserts, and deletes
  in an explicit database transaction (`BEGIN ... COMMIT`).
  """
  @spec commit_staged_changes(t()) :: t()
  def commit_staged_changes(%__MODULE__{datagrid_state: %DataGrid{} = grid} = app) do
    dirty = DataGrid.dirty_count(grid)
    {profile, schema} = Sidebar.resolve_selection_context(app)
    schema = schema || app.selected_schema
    tbl = app.selected_table

    cond do
      dirty == 0 ->
        %{app | status_message: "No pending changes to commit"}

      is_nil(profile) or not is_binary(tbl) or tbl == "" ->
        %{app | status_message: "❌ Cannot commit: no active database table selected"}

      true ->
        qualified = Sidebar.qualify_table(profile.driver, tbl, schema)

        pks =
          if grid.primary_keys != [] do
            grid.primary_keys
          else
            case Strata.DataStore.get_schema_cache(profile.id, schema, tbl) do
              {:ok, %{primary_keys: cached}} -> cached
              _ -> []
            end
          end

        case Strata.QueryBuilder.build_batch(profile.driver, qualified, grid.columns, grid.rows,
               pending_edits: grid.pending_edits,
               pending_inserts: grid.pending_inserts,
               pending_deletes: grid.pending_deletes,
               primary_keys: pks
             ) do
          {:ok, statements} ->
            req_id = System.unique_integer([:positive])
            caller = self()

            Task.start(fn ->
              res = Strata.ConnectionWorker.execute_transaction_for_profile(profile, statements)
              send(caller, {:commit_finished, req_id, profile.id, schema, tbl, res})
            end)

            %{
              app
              | status_message: "⏳ Committing #{length(statements)} statement(s) to '#{tbl}'..."
            }

          {:error, reason} ->
            %{app | status_message: "❌ Cannot build commit SQL: #{inspect(reason)}"}
        end
    end
  end

  def commit_staged_changes(app), do: app

  defp execute_actions_modal_item(app, action_id) do
    grid = app.datagrid_state || DataGrid.new()

    case action_id do
      :commit_changes ->
        commit_staged_changes(app)

      :revert_changes ->
        %{
          app
          | datagrid_state: DataGrid.revert_staged_changes(grid),
            status_message: "Reverted all staged changes"
        }

      :edit_cell ->
        start_inline_edit(app)

      :insert_row ->
        %{app | datagrid_state: DataGrid.insert_blank_row(grid)}

      :delete_row ->
        {r, _c} = grid.selected_cell
        %{app | datagrid_state: DataGrid.toggle_delete_row(grid, r)}

      :sort_col ->
        if grid.mode == :selecting do
          {_r, c} = grid.selected_cell
          sort_active_table_by_col(app, c)
        else
          open_sort_picker(app)
        end

      :clear_sort ->
        cleared = %{grid | sort_by: nil}

        cond do
          is_map(app.active_filter) ->
            apply_smart_filter(%{app | datagrid_state: cleared})

          app.active_view == :table_view and is_binary(app.selected_table) ->
            refresh_active_table(%{app | datagrid_state: cleared})

          true ->
            %{app | datagrid_state: cleared, status_message: "Cleared sort"}
        end

      :toggle_structure ->
        toggle_structure_view(app)

      :filter_table ->
        open_filter_bar(app)

      :filter_by_cell ->
        filter_by_selected_cell(app)

      :clear_filter ->
        clear_table_filter(app)

      :toggle_inspector ->
        toggle_inspector(app)

      :export_data ->
        push_modal(app, FilterExportModal.new(:export))

      :copy_cell ->
        handle_key(%{app | focus: :datagrid, datagrid_state: %{grid | mode: :selecting}}, "c")

      :copy_row ->
        handle_key(%{app | focus: :datagrid, datagrid_state: %{grid | mode: :selecting}}, "Y")

      :next_page ->
        %{app | datagrid_state: DataGrid.next_page(grid)}

      :prev_page ->
        %{app | datagrid_state: DataGrid.prev_page(grid)}

      :refresh ->
        refresh_active_table(app)

      _ ->
        app
    end
  end

  defp start_throbber_timer(app) do
    app = cancel_throbber_timer(app)
    timer = Process.send_after(self(), :throbber_tick, 80)
    %{app | throbber_timer: timer, throbber_step: 0}
  end

  defp cancel_throbber_timer(%{throbber_timer: ref} = app) when is_reference(ref) do
    _ = Process.cancel_timer(ref)
    %{app | throbber_timer: nil}
  end

  defp cancel_throbber_timer(app), do: app

  defp pointer_for_position(%__MODULE__{modals: [_ | _]} = app, x, y) do
    modal_area = Renderer.modal_area_for(app, app.window_size)
    if inside_area?(x, y, modal_area), do: :pointer, else: :default
  end

  defp pointer_for_position(app, x, y) do
    layout = Renderer.layout(app.window_size, app.active_view)
    areas = Renderer.datagrid_areas(layout.datagrid, app)
    dd = Renderer.filter_dropdown_data(app, layout.datagrid)
    sp = Renderer.sort_picker_data(app, layout.datagrid)

    cond do
      inside_area?(x, y, layout.footer) ->
        :pointer

      dd != nil and inside_area?(x, y, dd.rect) ->
        :pointer

      sp != nil and inside_area?(x, y, sp.rect) ->
        :pointer

      app.active_view == :query_view and inside_area?(x, y, layout.editor) ->
        :text

      areas.filter_area != nil and inside_area?(x, y, areas.filter_area) ->
        rects = Renderer.filter_bar_rects(areas.filter_area, app)

        if inside_area?(x, y, rects.val_rect), do: :text, else: :pointer

      inside_area?(x, y, areas.grid_area) and y == areas.grid_area.y + 1 ->
        :pointer

      true ->
        :default
    end
  end

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
    profile = Sidebar.resolve_profile_for_selection(app)

    if profile do
      target_pid = self()
      offset = length(grid.rows)
      batch_size = grid.batch_size || 100
      schema = app.selected_schema

      Task.start(fn ->
        result =
          Sidebar.fetch_table_chunk(profile, table_name, offset, batch_size,
            schema: schema,
            order_by: grid.sort_by
          )

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
  Asynchronously executes active SQL tab content so the TUI render loop never blocks.
  """
  @spec execute_sql_query_async(t()) :: t()
  def execute_sql_query_async(%__MODULE__{tabs: tabs, active_tab_id: active_id} = app) do
    active_tab = Enum.find(tabs, &(&1.id == active_id))
    sql = if active_tab, do: String.trim(active_tab.content), else: ""

    if sql == "" do
      %{app | status_message: "⚠️ Cannot execute empty SQL query"}
    else
      profile = Sidebar.resolve_profile_for_selection(app)

      if profile do
        caller = self()
        ddl? = Regex.match?(~r/^\s*(CREATE|DROP|ALTER|TRUNCATE)\b/i, sql)

        Task.start(fn ->
          start_time = System.monotonic_time(:millisecond)
          res = Strata.ConnectionWorker.execute_query_for_profile(profile, sql)
          elapsed = max(1, System.monotonic_time(:millisecond) - start_time)
          send(caller, {:sql_query_finished, elapsed, profile, ddl?, res})
        end)

        %{app | status_message: "⏳ Executing SQL query..."}
      else
        %{app | status_message: "❌ No active database connection configured"}
      end
    end
  end

  @doc """
  Executes active SQL tab content synchronously against connected DB profile.
  Preserves raw cell values for `Strata.Formatter` and `CellDetailModal`.
  """
  @spec execute_sql_query(t()) :: t()
  def execute_sql_query(%__MODULE__{tabs: tabs, active_tab_id: active_id} = app) do
    active_tab = Enum.find(tabs, &(&1.id == active_id))
    sql = if active_tab, do: String.trim(active_tab.content), else: ""

    if sql == "" do
      %{app | status_message: "⚠️ Cannot execute empty SQL query"}
    else
      profile = Sidebar.resolve_profile_for_selection(app)

      if profile do
        start_time = System.monotonic_time(:millisecond)
        res = Strata.ConnectionWorker.execute_query_for_profile(profile, sql)
        elapsed = max(1, System.monotonic_time(:millisecond) - start_time)

        case res do
          {:ok, %{columns: cols, rows: rows}} ->
            grid = DataGrid.new(cols, rows, has_more: false, loading_more: false)

            app
            |> switch_view(:query_view)
            |> Map.put(:datagrid_state, grid)
            |> Map.put(
              :status_message,
              "⚡ Query executed successfully (#{length(rows)} rows in #{elapsed}ms)"
            )

          {:error, reason} ->
            msg = if is_binary(reason), do: reason, else: inspect(reason)
            err_grid = DataGrid.new(["error"], [[msg]], has_more: false, loading_more: false)

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
  def handle_key(%__MODULE__{datagrid_state: %DataGrid{editing_cell: {_r, _c}}} = app, key) do
    handle_inline_edit_key(app, key)
  end

  def handle_key(%__MODULE__{filter_bar_open: true, filter_bar_focused: true} = app, key) do
    handle_filter_bar_key(app, key)
  end

  def handle_key(%__MODULE__{sort_picker_open: true} = app, key) do
    handle_sort_picker_key(app, key)
  end

  def handle_key(%__MODULE__{} = app, {:ctrl, "v"}) do
    case Strata.Clipboard.paste() do
      {:ok, ""} -> %{app | status_message: "📋 Clipboard is empty"}
      {:ok, text} -> paste_text(app, text)
      {:error, _} -> %{app | status_message: "📋 Paste failed (no OS clipboard tool)"}
    end
  end

  def handle_key(%__MODULE__{modals: [top | rest]} = app, key) do
    case key do
      :esc ->
        {_popped, app} = pop_modal(app)
        app

      _ ->
        cond do
          match?(%ActionsModal{}, top) ->
            case ActionsModal.handle_key(top, key) do
              {:execute, action_id, _modal} ->
                {_popped, app} = pop_modal(app)
                execute_actions_modal_item(app, action_id)

              {:cancel, _modal} ->
                {_popped, app} = pop_modal(app)
                app

              %ActionsModal{} = updated_modal ->
                %{app | modals: [updated_modal | rest]}
            end

          match?(%ConnectionModal{}, top) or match?(%{type: :connection_modal}, top) ->
            cm =
              case top do
                %ConnectionModal{} = modal -> modal
                _ -> ConnectionModal.new()
              end

            case ConnectionModal.handle_key(cm, key) do
              {:save, modal} ->
                profile = ConnectionModal.to_profile(modal)
                _ = Strata.ConnectionSupervisor.stop_worker(profile.id)
                _ = Strata.DataStore.invalidate_connection_cache(profile.id)

                try do
                  Strata.ConfigStore.put_profile(profile)
                catch
                  _, _ -> :ok
                end

                {_popped, app} = pop_modal(app)
                updated_nodes = Sidebar.load_nodes()

                %{app | sidebar_nodes: updated_nodes, selected_tree_node_id: profile.id}
                |> refresh_connection_schema_async(profile)

              {:cancel, _modal} ->
                {_popped, app} = pop_modal(app)
                app

              %ConnectionModal{} = updated_modal ->
                %{app | modals: [updated_modal | rest]}
            end

          match?(%SSHModal{}, top) or match?(%{type: :ssh_modal}, top) ->
            sm =
              case top do
                %SSHModal{} = modal -> modal
                _ -> SSHModal.new()
              end

            case SSHModal.handle_key(sm, key) do
              {:save, modal} ->
                ssh_profile = SSHModal.to_profile(modal)

                try do
                  Strata.SSHProfileStore.put_profile(ssh_profile)
                catch
                  _, _ -> :ok
                end

                {_popped, app} = pop_modal(app)

                %{
                  app
                  | status_message: "Saved SSH profile '#{ssh_profile.name}' (#{ssh_profile.id})"
                }

              {:delete, modal} ->
                try do
                  Strata.SSHProfileStore.delete_profile(modal.id)
                catch
                  _, _ -> :ok
                end

                {_popped, app} = pop_modal(app)
                %{app | status_message: "🗑️ Deleted SSH profile '#{modal.name}'"}

              {:cancel, _modal} ->
                {_popped, app} = pop_modal(app)
                app

              %SSHModal{} = updated_modal ->
                %{app | modals: [updated_modal | rest]}
            end

          match?(%{type: :confirm_delete_connection}, top) ->
            case key do
              k when k in ["y", "Y", :enter] ->
                {_popped, app} = pop_modal(app)
                Sidebar.delete_connection_by_id(app, top.profile_id)

              k when k in ["n", "N", :esc] ->
                {_popped, app} = pop_modal(app)
                %{app | status_message: "Cancelled connection delete"}

              _ ->
                app
            end

          match?(%CellDetailModal{}, top) or match?(%{type: :cell_detail_modal}, top) ->
            cell_modal =
              case top do
                %CellDetailModal{} = m -> m
                %{raw_value: val} -> CellDetailModal.new(val, column: Map.get(top, :column))
                %{content: val} -> CellDetailModal.new(val, column: Map.get(top, :column))
                _ -> CellDetailModal.new("")
              end

            case key do
              k when k in [:enter, :space, :esc, "q", "Q", :quit] ->
                {_popped, app} = pop_modal(app)
                app

              k when k in ["c", "C", "y", {:ctrl, "c"}] ->
                copy_str =
                  if cell_modal.format == :json do
                    cell_modal.formatted_value
                  else
                    DataGrid.format_cell_for_copy(cell_modal.raw_value)
                  end

                col_label = cell_modal.column || "Cell"

                status =
                  case Strata.Clipboard.copy(copy_str) do
                    :ok -> "📋 Copied #{col_label} from inspector"
                    {:error, _} -> "📋 Copy failed (no OS clipboard tool)"
                  end

                %{app | status_message: status}

              _ ->
                updated = CellDetailModal.handle_key(cell_modal, key)
                %{app | modals: [updated | rest]}
            end

          match?(%FilterExportModal{}, top) ->
            case FilterExportModal.handle_key(top, key) do
              {:apply, {:filter, where_clause, order_by_clause, limit}, modal} ->
                {_popped, app} = pop_modal(app)
                apply_table_filter(app, modal, where_clause, order_by_clause, limit)

              {:apply, {:export, format, file_path, scope}, modal} ->
                {_popped, app} = pop_modal(app)
                export_grid_data(app, modal, format, file_path, scope)

              {:cancel, _modal} ->
                {_popped, app} = pop_modal(app)
                app

              %FilterExportModal{} = updated_modal ->
                %{app | modals: [updated_modal | rest]}
            end

          match?(%{type: :filter_modal}, top) ->
            handle_key(%{app | modals: [FilterExportModal.new(:filter) | rest]}, key)

          match?(%{type: :export_modal}, top) ->
            handle_key(%{app | modals: [FilterExportModal.new(:export) | rest]}, key)

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
  def handle_key(%__MODULE__{} = app, :f3), do: toggle_structure_view(app)
  def handle_key(%__MODULE__{} = app, :f4), do: toggle_inspector(app)

  def handle_key(%__MODULE__{focus: focus} = app, "?") when focus != :editor do
    grid = app.datagrid_state || DataGrid.new()
    push_modal(app, ActionsModal.new(grid, app.active_view))
  end

  def handle_key(%__MODULE__{} = app, {:ctrl, "1"}), do: switch_view(app, :table_view)
  def handle_key(%__MODULE__{} = app, {:ctrl, "2"}), do: switch_view(app, :query_view)
  def handle_key(%__MODULE__{} = app, {:ctrl, "3"}), do: set_focus(app, :datagrid)

  def handle_key(%__MODULE__{focus: focus} = app, "1") when focus != :editor,
    do: switch_view(app, :table_view)

  def handle_key(%__MODULE__{focus: focus} = app, "2") when focus != :editor,
    do: switch_view(app, :query_view)

  def handle_key(%__MODULE__{focus: focus} = app, "3") when focus != :editor,
    do: set_focus(app, :datagrid)

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
    %{grid_area: grid_area} = Renderer.datagrid_areas(layout.datagrid, app)
    vh = max(1, grid_area.height - 3)
    max_w = max(1, grid_area.width - 3)

    grid = app.datagrid_state || DataGrid.new()
    prev_cell = grid.selected_cell
    {app, updated_grid} = DataGrid.handle_key(app, grid, key, viewport_h: vh, max_width: max_w)

    app =
      if updated_grid.selected_cell != prev_cell do
        %{
          app
          | datagrid_state: updated_grid,
            inspector_value_scroll: 0,
            inspector_summary_scroll: 0
        }
      else
        %{app | datagrid_state: updated_grid}
      end

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

  defp apply_table_filter(app, modal, where_clause, order_by_clause, limit) do
    trimmed_where = String.trim(to_string(where_clause || ""))
    trimmed_order = String.trim(to_string(order_by_clause || ""))

    if trimmed_where == "" and trimmed_order == "" and is_nil(limit) do
      app
      |> Map.put(:active_filter, nil)
      |> refresh_active_table()
      |> Map.put(:status_message, "Filter cleared — showing full table")
    else
      table_name = app.selected_table
      {profile, schema} = Sidebar.resolve_selection_context(app)
      schema = schema || app.selected_schema
      filter_state = %{where: trimmed_where, order_by: trimmed_order, limit: limit}
      app = %{app | active_filter: filter_state}

      if is_binary(table_name) and profile != nil do
        qualified = Sidebar.qualify_table(profile.driver, table_name, schema)
        sql = FilterExportModal.build_filter_sql(modal, qualified)
        caller = self()

        Task.start(fn ->
          res = Strata.ConnectionWorker.execute_query_for_profile(profile, sql)
          send(caller, {:filter_query_finished, trimmed_where, trimmed_order, res})
        end)

        %{app | status_message: "⏳ Applying filter..."}
      else
        %{app | status_message: "Filter applied: " <> trimmed_where}
      end
    end
  end

  defp export_grid_data(app, modal, format, file_path, scope) do
    grid = app.datagrid_state || DataGrid.new()

    rows =
      case scope do
        :current_page -> DataGrid.page_rows(grid)
        _ -> grid.rows
      end

    formatted =
      FilterExportModal.format_export(modal, grid.columns, rows,
        table_name: app.selected_table || "export_table"
      )

    case File.write(file_path, formatted) do
      :ok ->
        %{
          app
          | status_message: "📤 Exported #{length(rows)} rows (#{format}) to #{file_path}"
        }

      {:error, reason} ->
        %{app | status_message: "❌ Export failed: #{inspect(reason)}"}
    end
  end

  @doc """
  Handles mouse click and scroll wheel events.
  Locks background scrolling and supports outside-click dismissal when modals are open.
  """
  @spec handle_mouse(t(), any()) :: t()
  def handle_mouse(
        %__MODULE__{modals: [%ActionsModal{} = am | rest]} = app,
        {:scroll, dir, _x, _y}
      ) do
    max_idx = max(0, length(am.items) - 1)

    next =
      if dir in [:up, :scroll_up] do
        max(0, am.selected_index - 1)
      else
        min(max_idx, am.selected_index + 1)
      end

    %{app | modals: [%{am | selected_index: next} | rest]}
  end

  def handle_mouse(%__MODULE__{modals: [_ | _]} = app, {:scroll, _dir, _x, _y}) do
    # Modal scroll lock: prevent scroll bleed into background panes
    app
  end

  def handle_mouse(%__MODULE__{modals: [_ | _], window_size: ws} = app, {:click, x, y}) do
    modal_area = Renderer.modal_area_for(app, ws)

    if inside_area?(x, y, modal_area) do
      handle_modal_click(app, x, y, modal_area)
    else
      {_popped, updated} = pop_modal(app)
      updated
    end
  end

  def handle_mouse(
        %__MODULE__{filter_dropdown: kind, window_size: ws, active_view: active_view} = app,
        {:scroll, dir, _x, _y}
      )
      when kind in [:column, :op] do
    layout = Renderer.layout(ws, active_view)
    dd = Renderer.filter_dropdown_data(app, layout.datagrid)
    items = (dd && dd.items) || []
    max_idx = max(0, length(items) - 1)

    cond do
      dir in [:up, :scroll_up] ->
        %{app | filter_dropdown_idx: max(0, (app.filter_dropdown_idx || 0) - 1)}

      dir in [:down, :scroll_down] ->
        %{app | filter_dropdown_idx: min(max_idx, (app.filter_dropdown_idx || 0) + 1)}

      true ->
        app
    end
  end

  def handle_mouse(
        %__MODULE__{sort_picker_open: true, window_size: ws, active_view: active_view} = app,
        {:scroll, dir, _x, _y}
      ) do
    layout = Renderer.layout(ws, active_view)
    sp = Renderer.sort_picker_data(app, layout.datagrid)
    items = (sp && sp.items) || []
    max_idx = max(0, length(items) - 1)

    cond do
      dir in [:up, :scroll_up] ->
        %{app | sort_picker_idx: max(0, (app.sort_picker_idx || 0) - 1)}

      dir in [:down, :scroll_down] ->
        %{app | sort_picker_idx: min(max_idx, (app.sort_picker_idx || 0) + 1)}

      true ->
        app
    end
  end

  def handle_mouse(
        %__MODULE__{sort_picker_open: true, window_size: ws, active_view: active_view} = app,
        {:click, x, y}
      ) do
    layout = Renderer.layout(ws, active_view)
    sp = Renderer.sort_picker_data(app, layout.datagrid)

    if sp != nil and inside_area?(x, y, sp.rect) do
      rel_y = y - sp.rect.y - 1
      inner_h = max(1, sp.rect.height - 2)

      scroll_top =
        if length(sp.items) > inner_h, do: max(0, sp.selected_index - inner_h + 1), else: 0

      if rel_y >= 0 and rel_y < inner_h do
        select_sort_picker_item(app, Enum.at(sp.items, scroll_top + rel_y))
      else
        app
      end
    else
      %{app | sort_picker_open: false, sort_picker_search: ""}
    end
  end

  def handle_mouse(
        %__MODULE__{window_size: ws, active_view: active_view} = app,
        {:scroll, dir, x, y}
      ) do
    layout = Renderer.layout(ws, active_view)

    cond do
      inside_area?(x, y, layout.sidebar) ->
        visible = Sidebar.visible_nodes(app)
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
        %{grid_area: grid_area, inspector_area: inspector_area} =
          Renderer.datagrid_areas(layout.datagrid, app)

        if inspector_area != nil and inside_area?(x, y, inspector_area) do
          if dir in [:up, :scroll_up, :down, :scroll_down] do
            {allow?, new_lock} = evaluate_scroll_lock(app.scroll_lock, :vertical)
            app = %{app | scroll_lock: new_lock}

            if allow? do
              insp_areas = Renderer.inspector_areas(inspector_area)
              delta = if dir in [:up, :scroll_up], do: -3, else: 3

              if insp_areas.summary_area != nil and inside_area?(x, y, insp_areas.summary_area) do
                scroll_inspector(app, :summary, delta)
              else
                scroll_inspector(app, :value, delta)
              end
            else
              app
            end
          else
            app
          end
        else
          grid = app.datagrid_state || DataGrid.new()
          vh = max(1, grid_area.height - 3)
          max_w = max(1, grid_area.width - 3)

          is_bottom_bar? = y >= grid_area.y + grid_area.height - 1

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
          {allow?, new_app_lock} = evaluate_scroll_lock(app.scroll_lock, raw_axis)

          if allow? do
            step = if raw_direction in [:up, :down], do: 3, else: 1

            updated_grid =
              DataGrid.scroll_viewport(grid, raw_direction, vh, max_width: max_w, step: step)

            app = %{
              app
              | datagrid_state: updated_grid,
                focus: :datagrid,
                scroll_lock: new_app_lock
            }

            if active_view == :table_view and raw_direction == :down and
                 DataGrid.near_bottom?(updated_grid, vh, 25) do
              load_more_table_data(app)
            else
              app
            end
          else
            %{app | scroll_lock: new_app_lock}
          end
        end

      true ->
        app
    end
  end

  def handle_mouse(%__MODULE__{window_size: ws, active_view: active_view} = app, {:click, x, y}) do
    layout = Renderer.layout(ws, active_view)

    cond do
      inside_area?(x, y, layout.footer) ->
        handle_footer_click(app, x, y, layout.footer)

      inside_area?(x, y, layout.sidebar) ->
        app =
          app
          |> cancel_inline_edit_if_active()
          |> set_focus(:sidebar)

        rel_y = y - layout.sidebar.y - 1

        visible = Sidebar.visible_nodes(app)
        sidebar_viewport_h = max(1, layout.sidebar.height - 2)
        sidebar_scroll_top = app.sidebar_scroll_offset || 0
        target_idx = sidebar_scroll_top + rel_y

        if rel_y >= 0 and rel_y < sidebar_viewport_h and target_idx >= 0 and
             target_idx < length(visible) do
          target_item = Enum.at(visible, target_idx)

          if target_item do
            new_offset =
              clamp_sidebar_offset(
                sidebar_scroll_top,
                target_idx,
                sidebar_viewport_h,
                length(visible)
              )

            app = %{
              app
              | selected_tree_node_id: target_item.id,
                sidebar_scroll_offset: new_offset
            }

            app =
              if target_item.type in [:table, :view] do
                Sidebar.load_table_data(app, target_item.label)
              else
                Sidebar.handle_key(app, :enter)
              end

            updated_visible =
              Sidebar.flatten_visible_nodes(app.sidebar_nodes, app.selected_tree_node_id)

            updated_sel_idx =
              Enum.find_index(updated_visible, &(&1.id == app.selected_tree_node_id)) || 0

            final_offset =
              clamp_sidebar_offset(
                app.sidebar_scroll_offset || 0,
                updated_sel_idx,
                sidebar_viewport_h,
                length(updated_visible)
              )

            %{app | sidebar_scroll_offset: final_offset}
          else
            app
          end
        else
          app
        end

      layout.editor.height > 0 and inside_area?(x, y, layout.editor) ->
        app =
          app
          |> cancel_inline_edit_if_active()
          |> set_focus(:editor)

        if y == layout.editor.y and app.tabs != [] do
          rel_x = max(0, x - layout.editor.x)
          tab_idx = min(length(app.tabs) - 1, div(rel_x, 14))
          target_tab = Enum.at(app.tabs, tab_idx)
          if target_tab, do: switch_tab(app, target_tab.id), else: app
        else
          place_editor_cursor_at_click(app, x, y, layout.editor)
        end

      layout.datagrid.height > 0 and inside_area?(x, y, layout.datagrid) ->
        handle_datagrid_click(app, x, y, layout)

      true ->
        app
    end
  end

  def handle_mouse(app, _event), do: app

  defp evaluate_scroll_lock(scroll_lock, raw_axis) do
    now = System.monotonic_time(:millisecond)
    {locked_axis, last_time, burst_count} = scroll_lock || {nil, 0, 0}
    dt = now - last_time
    idle_timeout? = dt > 150

    {current_axis, new_burst_count, new_lock} =
      if idle_timeout? or locked_axis == nil do
        {raw_axis, 1, {raw_axis, now, 1}}
      else
        cnt = burst_count + 1
        {locked_axis, cnt, {locked_axis, now, cnt}}
      end

    is_inertia_tail? = not idle_timeout? and new_burst_count > 4 and dt > 35
    is_h_damped? = raw_axis == :horizontal and not idle_timeout? and rem(new_burst_count, 2) != 0
    allow? = raw_axis == current_axis and not is_inertia_tail? and not is_h_damped?
    {allow?, new_lock}
  end

  defp cancel_inline_edit_if_active(
         %__MODULE__{datagrid_state: %DataGrid{editing_cell: {_r, _c}} = grid} = app
       ) do
    %{app | datagrid_state: %{grid | editing_cell: nil}, inline_input_ref: nil}
  end

  defp cancel_inline_edit_if_active(app), do: app

  defp handle_modal_click(%__MODULE__{modals: [top | rest]} = app, _x, y, modal_area) do
    rel_y = y - modal_area.y - 1

    cond do
      match?(%ActionsModal{}, top) and rel_y >= 0 ->
        inner_h = max(1, modal_area.height - 2)

        scroll_top =
          if length(top.items) > inner_h, do: max(0, top.selected_index - inner_h + 1), else: 0

        case Enum.at(top.items, scroll_top + rel_y) do
          %{id: action_id} ->
            {_popped, app} = pop_modal(app)
            execute_actions_modal_item(app, action_id)

          nil ->
            app
        end

      match?(%ConnectionModal{}, top) and rel_y >= 0 ->
        fields = ConnectionModal.visible_fields(top.driver)

        case Enum.at(fields, rel_y) do
          nil ->
            app

          field when field in [:save_button, :cancel_button] ->
            updated_top = %{top | focused_field: field}
            handle_key(%{app | modals: [updated_top | rest]}, :enter)

          :test_button ->
            updated_top = %{top | focused_field: :test_button}
            test_connection_async(%{app | modals: [updated_top | rest]})

          field ->
            %{app | modals: [%{top | focused_field: field} | rest]}
        end

      match?(%SSHModal{}, top) and rel_y >= 0 ->
        fields = SSHModal.visible_fields(top)

        case Enum.at(fields, rel_y) do
          nil ->
            app

          field when field in [:save_button, :delete_button, :cancel_button] ->
            updated_top = %{top | focused_field: field}
            handle_key(%{app | modals: [updated_top | rest]}, :enter)

          :test_button ->
            updated_top = %{top | focused_field: :test_button}
            test_ssh_async(%{app | modals: [updated_top | rest]})

          field ->
            %{app | modals: [%{top | focused_field: field} | rest]}
        end

      match?(%FilterExportModal{}, top) and rel_y >= 0 ->
        fields =
          if top.mode == :filter do
            [:where, :order_by, :limit, :apply_button, :clear_button, :cancel_button]
          else
            [:format, :file_path, :scope, :export_button, :cancel_button]
          end

        case Enum.at(fields, rel_y) do
          nil ->
            app

          field when field in [:apply_button, :clear_button, :export_button, :cancel_button] ->
            updated_top = %{top | focused_field: field}
            handle_key(%{app | modals: [updated_top | rest]}, :enter)

          field ->
            %{app | modals: [%{top | focused_field: field} | rest]}
        end

      true ->
        app
    end
  end

  defp handle_datagrid_click(app, x, y, layout) do
    app =
      app
      |> cancel_inline_edit_if_active()
      |> set_focus(:datagrid)

    areas = Renderer.datagrid_areas(layout.datagrid, app)
    dd = Renderer.filter_dropdown_data(app, layout.datagrid)

    cond do
      dd != nil and inside_area?(x, y, dd.rect) ->
        rel_y = y - dd.rect.y - 1
        inner_h = max(1, dd.rect.height - 2)

        scroll_top =
          if length(dd.items) > inner_h, do: max(0, dd.selected_index - inner_h + 1), else: 0

        if rel_y >= 0 and rel_y < inner_h do
          select_filter_dropdown_item(app, Enum.at(dd.items, scroll_top + rel_y))
        else
          app
        end

      areas.filter_area != nil and inside_area?(x, y, areas.filter_area) ->
        rects = Renderer.filter_bar_rects(areas.filter_area, app)

        cond do
          inside_area?(x, y, rects.run_rect) ->
            handle_filter_value_key(%{app | filter_dropdown: nil}, :enter)

          inside_area?(x, y, rects.clear_rect) ->
            clear_table_filter(app)

          inside_area?(x, y, rects.mode_rect) ->
            next_mode = if app.filter_bar_mode == :raw, do: :builder, else: :raw

            %{
              app
              | filter_bar_focused: true,
                filter_bar_mode: next_mode,
                filter_bar_focus_part: :value,
                filter_dropdown: nil
            }

          rects.col_rect != nil and inside_area?(x, y, rects.col_rect) ->
            if app.filter_dropdown == :column do
              %{app | filter_dropdown: nil, filter_dropdown_search: ""}
            else
              open_filter_dropdown(app, :column)
            end

          rects.op_rect != nil and inside_area?(x, y, rects.op_rect) ->
            if app.filter_dropdown == :op do
              %{app | filter_dropdown: nil, filter_dropdown_search: ""}
            else
              open_filter_dropdown(app, :op)
            end

          true ->
            app =
              if app.filter_bar_open do
                %{
                  app
                  | filter_bar_focused: true,
                    filter_bar_focus_part: :value,
                    filter_dropdown: nil
                }
              else
                open_filter_bar(app)
              end

            app
        end

      areas.inspector_area != nil and inside_area?(x, y, areas.inspector_area) ->
        app = %{app | filter_bar_focused: false, filter_dropdown: nil}
        insp_areas = Renderer.inspector_areas(areas.inspector_area)

        cond do
          y == insp_areas.value_area.y ->
            %{app | inspector_open: false}

          insp_areas.summary_area != nil and inside_area?(x, y, insp_areas.summary_area) ->
            grid = app.datagrid_state || DataGrid.new()
            rel_y = y - insp_areas.summary_area.y - 1
            sum_vp = max(1, insp_areas.summary_area.height - 2)
            target_col = (app.inspector_summary_scroll || 0) + rel_y

            if rel_y >= 0 and rel_y < sum_vp and target_col >= 0 and
                 target_col < length(grid.columns) do
              {r_idx, _c} = grid.selected_cell
              updated_grid = %{grid | selected_cell: {r_idx, target_col}, mode: :selecting}
              %{app | datagrid_state: updated_grid, inspector_value_scroll: 0}
            else
              app
            end

          true ->
            app
        end

      true ->
        app = %{app | filter_bar_focused: false, filter_dropdown: nil}
        grid_area = areas.grid_area
        grid = app.datagrid_state || DataGrid.new()

        grid_y = grid_area.y
        grid_x = grid_area.x

        header_offset = 2
        rel_y = y - grid_y - header_offset
        is_bottom_bar? = y >= grid_area.y + grid_area.height - 1

        eff_rows = DataGrid.effective_rows(grid)

        cond do
          is_bottom_bar? ->
            vh = max(1, grid_area.height - 3)
            max_w = max(1, grid_area.width - 3)
            mid_x = grid_x + div(grid_area.width, 2)
            dir = if x < mid_x, do: :left, else: :right
            updated_grid = DataGrid.move_selection(grid, dir, vh, max_width: max_w)
            %{app | datagrid_state: updated_grid}

          rel_y == -1 and grid.columns != [] ->
            rel_x = max(0, x - grid_x - 1)
            max_width = max(1, grid_area.width - 3)
            {_local_col, target_col, _col_offset} = DataGrid.col_at_x(grid, rel_x, max_width)
            sort_active_table_by_col(app, target_col)

          rel_y >= 0 and eff_rows != [] ->
            viewport_h = max(1, grid_area.height - 3)
            total_r = length(eff_rows)
            max_top = max(0, total_r - viewport_h)
            curr_scroll = min(grid.scroll_offset || 0, max_top)

            visible_row_count = max(0, min(viewport_h, total_r - curr_scroll))

            if rel_y < visible_row_count do
              target_row = curr_scroll + rel_y
              rel_x = max(0, x - grid_x - 1)

              max_width = max(1, grid_area.width - 3)
              {_local_col, target_col, col_offset} = DataGrid.col_at_x(grid, rel_x, max_width)

              now = System.monotonic_time(:millisecond)

              double_clicked? =
                case app.last_grid_click do
                  {{^target_row, ^target_col}, prev_ts} ->
                    grid.mode == :selecting and now - prev_ts <= 500

                  _ ->
                    false
                end

              new_scroll =
                cond do
                  target_row < curr_scroll ->
                    max(0, target_row)

                  target_row >= curr_scroll + viewport_h ->
                    min(max_top, target_row - viewport_h + 1)

                  true ->
                    curr_scroll
                end

              updated_grid = %{
                grid
                | selected_cell: {target_row, target_col},
                  scroll_offset: new_scroll,
                  col_offset: col_offset,
                  mode: :selecting
              }

              app =
                app
                |> Map.put(:datagrid_state, updated_grid)
                |> Map.put(:last_grid_click, {{target_row, target_col}, now})
                |> Map.put(:inspector_value_scroll, 0)
                |> Map.put(:inspector_summary_scroll, 0)

              if double_clicked? do
                raw_cell = eff_rows |> Enum.at(target_row, []) |> Enum.at(target_col, nil)
                col_name = Enum.at(grid.columns, target_col, "Cell")

                cell_modal =
                  CellDetailModal.new(raw_cell, column: col_name, row_index: target_row + 1)

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
  end

  defp handle_footer_click(app, x, y, footer_area) do
    actions = Strata.UI.Components.Footer.clickable_actions(app, footer_area)

    case Enum.find(actions, &inside_area?(x, y, &1.area)) do
      %{key: :"ctrl+1/2"} ->
        next_view = if app.active_view == :table_view, do: :query_view, else: :table_view
        switch_view(app, next_view)

      %{key: :tab} ->
        cycle_focus(app, :next)

      %{key: :a} ->
        push_modal(app, ConnectionModal.new())

      %{key: :e} ->
        handle_key(app, "e")

      %{key: :d} ->
        handle_key(app, "d")

      %{key: :s} ->
        if app.focus == :sidebar, do: push_modal(app, SSHModal.new()), else: handle_key(app, "s")

      %{key: :o} ->
        handle_key(app, "o")

      %{key: :/} ->
        handle_key(app, "/")

      %{key: :r} ->
        if app.focus == :sidebar do
          refresh_selected_connection_schema_async(app)
        else
          refresh_active_table(app)
        end

      %{key: :f} ->
        handle_key(app, "f")

      %{key: :v} ->
        handle_key(app, "v")

      %{key: :"v/esc"} ->
        handle_key(app, :esc)

      %{key: :c} ->
        handle_key(app, "c")

      %{key: :"?"} ->
        handle_key(app, "?")

      %{key: :"ctrl+s"} ->
        commit_staged_changes(app)

      %{key: :"ctrl+z"} ->
        handle_key(app, {:ctrl, "z"})

      %{key: :"ctrl+enter"} ->
        execute_sql_query(app)

      %{key: :"ctrl+t"} ->
        open_tab(app)

      %{key: :"ctrl+n"} ->
        handle_key(app, {:ctrl, "n"})

      %{key: :"i/d"} ->
        handle_key(app, "i")

      %{key: :"c/y"} ->
        handle_key(app, "c")

      %{key: :"e/d"} ->
        handle_key(app, "e")

      %{key: :"ctrl+v"} ->
        handle_key(app, {:ctrl, "v"})

      %{key: :"ctrl+u"} ->
        handle_key(app, {:ctrl, "u"})

      %{key: :"ctrl+l"} ->
        clear_table_filter(app)

      %{key: :"ctrl+r"} ->
        handle_key(app, {:ctrl, "r"})

      %{key: :"↓/esc"} ->
        handle_key(app, :esc)

      %{key: :enter} ->
        handle_key(app, :enter)

      %{key: :esc} ->
        handle_key(app, :esc)

      _ ->
        cond do
          x >= 0 and x <= 22 -> switch_view(app, :table_view)
          x >= 23 and x <= 45 -> switch_view(app, :query_view)
          true -> app
        end
    end
  end

  defp place_editor_cursor_at_click(app, x, y, editor_area) do
    active_tab = Enum.find(app.tabs, &(&1.id == app.active_tab_id))

    if active_tab do
      body_height = max(1, editor_area.height - 1)
      viewport_h = max(1, body_height - 2)
      {cur_row, _cur_col} = active_tab.cursor || {0, 0}
      scroll_top = max(0, cur_row - viewport_h + 1)

      # editor body starts at editor_area.y + 1 (tabs) + 1 (top border) = editor_area.y + 2
      rel_y = y - (editor_area.y + 2)
      # line prefix is 6 chars ("  1 │ ") plus 1 char left border = 7
      rel_x = max(0, x - (editor_area.x + 7))

      lines = String.split(active_tab.content || "", "\n")

      if rel_y >= 0 and rel_y < viewport_h do
        target_row = max(0, min(length(lines) - 1, scroll_top + rel_y))
        target_line = Enum.at(lines, target_row, "")
        target_col = max(0, min(String.length(target_line), rel_x))

        updated_tabs =
          Enum.map(app.tabs, fn t ->
            if t.id == active_tab.id, do: %{t | cursor: {target_row, target_col}}, else: t
          end)

        %{app | tabs: updated_tabs}
      else
        app
      end
    else
      app
    end
  end

  defp clamp_sidebar_offset(current_offset, selected_idx, viewport_h, total) do
    max_offset = max(0, total - viewport_h)

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
