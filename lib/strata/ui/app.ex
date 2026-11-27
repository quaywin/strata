defmodule Strata.UI.App do
  @moduledoc """
  State management for Database TUI interface.
  Manages focus panes, tabbed SQL editor, modal overlays stack, async DB operations,
  ETS caching, and tree view navigation.
  Integrated with ExRatatui.App behaviour for 60 FPS event-driven TUI.
  """
  use ExRatatui.App

  alias Strata.UI.Components.ActionsModal
  alias Strata.UI.Components.AIChatPanel
  alias Strata.UI.Components.AISettingsModal
  alias Strata.UI.Components.ConfirmModal
  alias Strata.UI.Components.ConnectionModal
  alias Strata.UI.Components.DataGrid
  alias Strata.UI.Components.ExportModal
  alias Strata.UI.Components.Sidebar
  alias Strata.UI.Components.SQLEditor
  alias Strata.UI.Components.SQLTabPickerModal
  alias Strata.UI.Components.UpdateModal
  alias Strata.UI.Renderer

  @type focus_pane :: :sidebar | :editor | :datagrid | :ai_panel
  @type active_view :: :table_view | :query_view

  @type tab_kind :: :table | :query
  @type tab :: map()

  @type t :: %__MODULE__{
          focus: focus_pane(),
          active_view: active_view(),
          selected_table: String.t() | nil,
          selected_schema: String.t() | nil,
          table_request_id: integer() | nil,
          tabs: [tab()],
          active_tab_id: String.t() | nil,
          closed_tabs: [map()],
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
          filter_bar_transient: boolean(),
          filter_bar_focus_part: :column | :op | :value | :sort,
          filter_bar_col: String.t(),
          filter_bar_op: atom(),
          filter_bar_ref: reference() | nil,
          filter_bar_text: String.t(),
          ai_request: map() | nil,
          ai_panel_open: boolean(),
          ai_panel_focus: :input | :history,
          ai_input_text: String.t(),
          ai_input_cursor: non_neg_integer(),
          ai_pastes: map(),
          ai_paste_seq: non_neg_integer(),
          ai_history_scroll: non_neg_integer(),
          ai_selected_msg_idx: non_neg_integer() | nil,
          filter_history: map(),
          filter_history_idx: non_neg_integer() | nil,
          filter_history_draft: map() | nil,
          filter_dropdown: :column | :op | :sort | nil,
          filter_dropdown_idx: non_neg_integer(),
          filter_dropdown_search: String.t(),
          inspector_open: boolean(),
          inspector_value_scroll: non_neg_integer(),
          inspector_summary_scroll: non_neg_integer(),
          inspector_format: :auto | :json | :text | :raw,
          sidebar_filter: String.t(),
          sidebar_filter_active: boolean(),
          drag_anchor: {integer(), integer()} | nil,
          text_selection: {{integer(), integer()}, {integer(), integer()}} | nil,
          selection_screen: map() | nil,
          selection_bounds: map() | nil,
          update_info: map() | nil,
          modal_dropdown: map() | nil,
          pending_commit_action:
            {:close_tab, String.t()} | {:refresh_tab, String.t() | nil, String.t()} | :quit | nil,
          quit_requested?: boolean()
        }

  defstruct focus: :sidebar,
            active_view: :query_view,
            selected_table: nil,
            selected_schema: nil,
            table_request_id: nil,
            tabs: [],
            active_tab_id: nil,
            closed_tabs: [],
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
            filter_bar_transient: false,
            filter_bar_focus_part: :value,
            filter_bar_col: "* All",
            filter_bar_op: :contains,
            filter_bar_ref: nil,
            filter_bar_text: "",
            ai_request: nil,
            ai_panel_open: false,
            ai_panel_focus: :input,
            ai_input_text: "",
            ai_input_cursor: 0,
            ai_pastes: %{},
            ai_paste_seq: 0,
            ai_history_scroll: 0,
            ai_selected_msg_idx: nil,
            filter_history: %{},
            filter_history_idx: nil,
            filter_history_draft: nil,
            filter_dropdown: nil,
            filter_dropdown_idx: 0,
            filter_dropdown_search: "",
            inspector_open: false,
            inspector_value_scroll: 0,
            inspector_summary_scroll: 0,
            inspector_format: :auto,
            sidebar_filter: "",
            sidebar_filter_active: false,
            drag_anchor: nil,
            text_selection: nil,
            selection_screen: nil,
            selection_bounds: nil,
            update_info: nil,
            modal_dropdown: nil,
            pending_commit_action: nil,
            quit_requested?: false

  @env Application.compile_env(:strata, :env, :prod)
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
        if mapped_key == {:ctrl, "w"} do
          {:noreply, close_tab(state, state.active_tab_id)}
        else
          {:noreply, handle_inline_edit_key(state, mapped_key)}
        end

      state.filter_bar_open and state.filter_bar_focused ->
        {:noreply, handle_filter_bar_key(state, mapped_key)}

      state.focus == :sidebar and state.sidebar_filter_active and Enum.empty?(state.modals) ->
        {:noreply, handle_sidebar_filter_key(state, mapped_key)}

      mapped_key in ["q", "Q"] and state.focus not in [:editor, :ai_panel] and
          Enum.empty?(state.modals) ->
        handle_quit_request(state)

      match?([%ConnectionModal{focused_field: :test_button} | _], state.modals) and
          mapped_key in [:enter, :space] ->
        {:noreply, test_connection_async(state)}

      match?([%AISettingsModal{focused_field: :test_button} | _], state.modals) and
          mapped_key in [:enter, :space] ->
        {:noreply, test_ai_cli_async(state)}

      mapped_key in [{:ctrl, "enter"}, {:ctrl, "r"}] and Enum.empty?(state.modals) ->
        if active_tab_kind(state) == :query do
          {:noreply, execute_sql_query_async(state)}
        else
          {:noreply, refresh_active_table(state)}
        end

      state.focus == :sidebar and mapped_key in [:enter, :space, " ", "r", "R", :f5] and
          Enum.empty?(state.modals) ->
        handle_sidebar_action_async(state, mapped_key)

      true ->
        new_state = handle_key(state, mapped_key)
        if new_state.quit_requested?, do: {:stop, new_state}, else: {:noreply, new_state}
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
            selection_bounds: nil,
            update_info: nil
        }

        {:noreply, new_state,
         render?: had_sel?, pointer: pointer_for_position(new_state, col, row)}

      kind_str == "drag" and left_button? ->
        latest_drag = drain_drag_events({:drag, col, row})
        new_state = handle_drag_select(state, latest_drag)
        {:noreply, new_state, pointer: pointer_for_position(new_state, col, row)}

      kind_str == "up" and left_button? ->
        new_state = handle_drag_finish(state, col, row)

        if new_state.quit_requested? do
          {:stop, new_state}
        else
          {:noreply, new_state, pointer: pointer_for_position(new_state, col, row)}
        end

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
      active_tab_scroll_offset(old_state) != active_tab_scroll_offset(new_state) or
      old_state.text_selection != new_state.text_selection or
      old_state.focus != new_state.focus or
      old_state.sidebar_scroll_offset != new_state.sidebar_scroll_offset or
      old_state.selected_tree_node_id != new_state.selected_tree_node_id or
      old_state.inspector_value_scroll != new_state.inspector_value_scroll or
      old_state.inspector_summary_scroll != new_state.inspector_summary_scroll or
      old_state.filter_dropdown_idx != new_state.filter_dropdown_idx or
      old_state.status_message != new_state.status_message or
      old_state.modals != new_state.modals
  end

  defp active_tab_scroll_offset(%{tabs: tabs, active_tab_id: active_id}) do
    case Enum.find(tabs, &(&1.id == active_id)) do
      %{} = tab -> Map.get(tab, :scroll_offset, 0)
      nil -> 0
    end
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

  @doc """
  Refreshes the selected sidebar connection schema or reloads the selected table/view.
  """
  @spec refresh_sidebar_selection(t()) :: t()
  def refresh_sidebar_selection(state) do
    visible = Sidebar.visible_nodes(state)
    selected_item = Enum.find(visible, &(&1.id == state.selected_tree_node_id))

    if selected_item && selected_item.type in [:table, :view] do
      {profile, schema} = Sidebar.resolve_selection_context(state)
      profile_id = profile && profile.id
      existing_tab = find_table_tab(state.tabs, profile_id, schema, selected_item.label)
      {staged_count, inline_editing?} = dirty_state_for_tab(state, existing_tab)

      if staged_count > 0 or inline_editing? do
        modal =
          ConfirmModal.new(
            kind: :refresh_dirty_table,
            tab_id: existing_tab && existing_tab.id,
            tab_name: selected_item.label,
            dirty_count: staged_count,
            inline_editing?: inline_editing?,
            can_commit?: true,
            focused_field: :cancel_button
          )

        push_modal(%{state | sidebar_filter_active: false}, modal)
      else
        load_table_async(%{state | sidebar_filter_active: false}, selected_item.label,
          refresh: true
        )
      end
    else
      refresh_selected_connection_schema_async(state)
    end
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

      key in ["r", "R"] ->
        {:noreply, refresh_sidebar_selection(state)}

      offline_or_loading? and key in [:enter, :space, " "] ->
        {:noreply, refresh_selected_connection_schema_async(state)}

      selected_item && selected_item.type in [:table, :view] ->
        {:noreply,
         load_table_async(%{state | sidebar_filter_active: false}, selected_item.label,
           refresh: false
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
    {state, restored?} = restore_workspace_tabs(state)
    profiles = safe_list_profiles()
    maybe_start_background_update_check(state)

    if restored? do
      {:noreply, start_schema_stream_tasks(state, profiles)}
    else
      {:noreply, start_schema_stream_tasks(state, profiles), render?: false}
    end
  end

  def handle_info({:connection_schema_loaded, profile_id, new_node}, state)
      when is_binary(profile_id) do
    updated_nodes = upsert_connection_node(state.sidebar_nodes, profile_id, new_node)

    first_id =
      case List.first(updated_nodes) do
        nil -> state.selected_tree_node_id
        n -> state.selected_tree_node_id || n.id
      end

    offline? = String.contains?(to_string(Map.get(new_node, :label, "")), "(Offline")

    if not offline? and Map.get(state, :terminal, false) do
      caller = self()

      Task.start(fn ->
        profile =
          try do
            Strata.ConfigStore.get_profile(profile_id)
          rescue
            _ -> nil
          catch
            :exit, _ -> nil
          end

        if match?(%Strata.ConnectionProfile{}, profile) do
          res = Strata.SchemaInspector.fetch_all_columns(profile)
          send(caller, {:columns_prefetched, profile_id, res})
        end
      end)
    end

    {:noreply, %{state | sidebar_nodes: updated_nodes, selected_tree_node_id: first_id}}
  end

  def handle_info({:columns_prefetched, profile_id, {:ok, entries}}, state)
      when is_binary(profile_id) and is_list(entries) do
    Enum.each(entries, fn {schema, table_name, cols} ->
      Strata.DataStore.put_columns_cache(profile_id, schema, table_name, cols)
    end)

    {:noreply, state, render?: false}
  end

  def handle_info({:columns_prefetched, _profile_id, _res}, state) do
    {:noreply, state, render?: false}
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

    if match?(%DataGrid{loading_more: true}, grid) or state.ai_request != nil do
      timer = Process.send_after(self(), :throbber_tick, 80)

      {:noreply,
       %{state | throbber_step: rem((state.throbber_step || 0) + 1, 64), throbber_timer: timer}}
    else
      {:noreply, %{state | throbber_timer: nil}, render?: false}
    end
  end

  def handle_info({:table_data_loaded, req_id, profile_id, schema, table_name, result}, state) do
    state =
      case find_tab_by_request(state.tabs, req_id, table_name) do
        %{id: tab_id} ->
          state = cancel_throbber_timer(state)

          case result do
            {:ok, cols, rows} ->
              has_more = length(rows) == 100

              Strata.DataStore.put_table_cache(
                profile_id,
                schema,
                table_name,
                cols,
                rows,
                has_more
              )

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

              state
              |> update_tab_by_id(tab_id, fn tab ->
                %{tab | datagrid_state: grid, structure_restore_grid: nil}
              end)
              |> Map.put(
                :status_message,
                "[DB] Loaded table '#{table_name}' (#{length(rows)} rows)"
              )

            {:error, reason} ->
              msg = Strata.Formatter.format_error(reason)
              err_grid = DataGrid.new(["error"], [[msg]], has_more: false, loading_more: false)

              state
              |> update_tab_by_id(tab_id, fn tab -> %{tab | datagrid_state: err_grid} end)
              |> Map.put(:status_message, "❌ Error loading table '#{table_name}': #{msg}")
          end

        nil ->
          state
      end

    {:noreply, state}
  end

  def handle_info({:table_count_loaded, req_id, table_name, {:ok, total_count}}, state) do
    state =
      case find_tab_by_request(state.tabs, req_id, table_name) do
        %{id: tab_id} ->
          update_tab_by_id(state, tab_id, fn tab ->
            if tab.datagrid_state != nil and tab.datagrid_state.view_mode == :data do
              %{tab | datagrid_state: %{tab.datagrid_state | total_db_rows: total_count}}
            else
              tab
            end
          end)

        nil ->
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
      state
      |> persist_active_tab()
      |> then(fn s ->
        updated_tabs =
          Enum.map(s.tabs, fn tab ->
            if tab.kind == :table and tab.table_name == table_name and tab.schema == schema and
                 (is_nil(tab.profile_id) or tab.profile_id == profile_id) and
                 tab.datagrid_state != nil do
              %{
                tab
                | datagrid_state: %{tab.datagrid_state | primary_keys: schema_info.primary_keys}
              }
            else
              tab
            end
          end)

        s = %{s | tabs: updated_tabs}

        case Enum.find(updated_tabs, &(&1.id == s.active_tab_id)) do
          nil -> s
          active -> hydrate_tab(s, active)
        end
      end)

    {:noreply, state, render?: false}
  end

  def handle_info({:table_schema_loaded, _req_id, _pid, _schema, _tbl, _err}, state) do
    {:noreply, state, render?: false}
  end

  def handle_info({:structure_view_loaded, req_id, profile_id, schema, table_name, result}, state) do
    state =
      case find_tab_by_request(state.tabs, req_id, table_name) do
        %{id: tab_id} ->
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

              state
              |> update_tab_by_id(tab_id, fn tab ->
                restore_grid =
                  case tab.structure_restore_grid do
                    %DataGrid{} = g -> %{g | primary_keys: schema_info.primary_keys}
                    other -> other
                  end

                %{tab | datagrid_state: struct_grid, structure_restore_grid: restore_grid}
              end)
              |> Map.put(
                :status_message,
                "Structure view '#{table_name}' (#{length(schema_info.rows)} columns)"
              )

            {:error, reason} ->
              msg = Strata.Formatter.format_error(reason)

              state
              |> update_tab_by_id(tab_id, fn tab ->
                restored = tab.structure_restore_grid || tab.datagrid_state
                %{tab | datagrid_state: restored, structure_restore_grid: nil}
              end)
              |> Map.put(:status_message, "❌ Schema inspect error: #{msg}")
          end

        nil ->
          state
      end

    {:noreply, state}
  end

  def handle_info({:table_sorted_loaded, req_id, table_name, sort_by, result}, state) do
    state =
      case find_tab_by_request(state.tabs, req_id, table_name) do
        %{id: tab_id} = target_tab ->
          state = cancel_throbber_timer(state)
          old_grid = target_tab.datagrid_state
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

              state
              |> update_tab_by_id(tab_id, fn tab -> %{tab | datagrid_state: grid} end)
              |> Map.put(:status_message, "#{sort_desc} (#{length(rows)} rows)")

            {:error, reason} ->
              msg = Strata.Formatter.format_error(reason)

              state
              |> update_tab_by_id(tab_id, fn tab ->
                %{tab | datagrid_state: %{tab.datagrid_state | loading_more: false}}
              end)
              |> Map.put(:status_message, "❌ Sort error: #{msg}")
          end

        nil ->
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

          case state.pending_commit_action do
            {:close_tab, tab_id} ->
              state
              |> pop_confirm_modal_if_present()
              |> Map.put(:pending_commit_action, nil)
              |> close_tab(tab_id, force: true)
              |> Map.put(
                :status_message,
                "✅ Committed #{stmt_count} statement(s) and closed '#{table_name}'"
              )

            {:refresh_tab, _tab_id, target_table} ->
              state
              |> pop_confirm_modal_if_present()
              |> Map.put(:pending_commit_action, nil)
              |> load_table_async(target_table, refresh: true)
              |> Map.put(
                :status_message,
                "✅ Committed #{stmt_count} statement(s) and refreshed '#{target_table}'"
              )

            :quit ->
              state
              |> pop_confirm_modal_if_present()
              |> Map.put(:pending_commit_action, nil)
              |> Map.put(:quit_requested?, true)
              |> Map.put(
                :status_message,
                "✅ Committed #{stmt_count} statement(s) to '#{table_name}'"
              )

            nil ->
              state
              |> load_table_async(table_name, refresh: true)
              |> Map.put(
                :status_message,
                "✅ Committed #{stmt_count} statement(s) to '#{table_name}'"
              )
          end

        {:error, reason} ->
          msg = Strata.Formatter.format_error(reason)

          if state.pending_commit_action != nil do
            case state.modals do
              [%ConfirmModal{} = cm | rest] ->
                updated_cm = %{
                  cm
                  | status: :error,
                    status_message: "❌ Commit rolled back (changes kept): #{msg}"
                }

                %{
                  state
                  | modals: [updated_cm | rest],
                    pending_commit_action: nil,
                    status_message: "❌ Commit rolled back: #{msg}"
                }

              _ ->
                %{
                  state
                  | pending_commit_action: nil,
                    status_message: "❌ Commit rolled back: #{msg}"
                }
            end
          else
            %{state | status_message: "❌ Commit rolled back: #{msg}"}
          end
      end

    if state.quit_requested?, do: {:stop, state}, else: {:noreply, state}
  end

  def handle_info({:connection_test_finished, res}, state) do
    state =
      case state.modals do
        [%ConnectionModal{} = cm | rest] ->
          updated_cm = ConnectionModal.apply_test_result(cm, res)
          %{state | modals: [updated_cm | rest]}

        _ ->
          state
      end

    {:noreply, state}
  end

  def handle_info({:ai_cli_test_finished, res}, state) do
    state =
      case state.modals do
        [%AISettingsModal{} = am | rest] ->
          updated_am =
            case res do
              {:ok, msg} ->
                %{am | status: :ok, status_message: msg}

              {:error, reason} ->
                msg = Strata.Formatter.format_error(reason)
                %{am | status: :error, status_message: "❌ AI CLI test failed: " <> msg}
            end

          %{state | modals: [updated_am | rest]}

        _ ->
          state
      end

    {:noreply, state}
  end

  def handle_info(
        {:startup_update_check_finished, {:ok, %{status: :update_available} = info}},
        state
      ) do
    status_msg =
      if state.status_message in [nil, "", "Ready"] do
        "🆕 Strata v#{info.latest_version} available — press [?] → Check for Updates"
      else
        state.status_message
      end

    {:noreply, %{state | update_info: info, status_message: status_msg}}
  end

  def handle_info({:startup_update_check_finished, {:ok, info}}, state) do
    {:noreply, %{state | update_info: info}, render?: false}
  end

  def handle_info({:startup_update_check_finished, _res}, state) do
    {:noreply, state, render?: false}
  end

  def handle_info({:update_check_finished, res}, state) do
    state =
      case res do
        {:ok, info} -> %{state | update_info: info}
        _ -> state
      end

    state =
      case state.modals do
        [%UpdateModal{} = um | rest] ->
          updated_um = UpdateModal.apply_check_result(um, res)
          %{state | modals: [updated_um | rest]}

        _ ->
          state
      end

    {:noreply, state}
  end

  def handle_info({:update_install_finished, res}, state) do
    state =
      case state.modals do
        [%UpdateModal{} = um | rest] ->
          updated_um = UpdateModal.apply_install_result(um, res)
          next_state = %{state | modals: [updated_um | rest]}

          case res do
            {:ok, result} ->
              %{
                next_state
                | update_info: nil,
                  status_message: "✅ Updated to v#{result.version} — quit [q] and restart strata"
              }

            _ ->
              next_state
          end

        _ ->
          state
      end

    {:noreply, state}
  end

  def handle_info({:ai_task_finished, req_id, :sql, tab_id, msg_id, res}, state) do
    case state.ai_request do
      %{id: ^req_id} ->
        state = %{state | ai_request: nil} |> cancel_throbber_timer()
        {:noreply, apply_ai_task_result(state, tab_id, msg_id, res)}

      _ ->
        {:noreply, state, render?: false}
    end
  end

  def handle_info({:filter_query_finished, tab_id, where_clause, order_by_clause, result}, state) do
    state = apply_filter_query_result(state, tab_id, where_clause, order_by_clause, result)
    {:noreply, state}
  end

  def handle_info({:sql_query_finished, tab_id, elapsed, profile, ddl?, result}, state) do
    state = apply_sql_query_result(state, tab_id, elapsed, result)

    state =
      if ddl? and match?({:ok, _}, result) and profile != nil do
        refresh_connection_schema_async(state, profile)
      else
        state
      end

    {:noreply, state}
  end

  def handle_info({:table_chunk_loaded, tab_id, table_name, _offset, result}, state) do
    state = apply_table_chunk_loaded(state, tab_id, table_name, result)
    {:noreply, state}
  end

  def handle_info({:query_chunk_loaded, tab_id, req_id, _offset, result}, state) do
    state = apply_query_chunk_loaded(state, tab_id, req_id, result)
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
            if Map.has_key?(child, :expanded?) do
              Map.put(
                child,
                :expanded?,
                Map.get(old_child, :expanded?, Map.get(child, :expanded?, false))
              )
            else
              child
            end
        end
      end)

    new_node
    |> Map.put(:expanded?, exp?)
    |> Map.put(:children, updated_children)
  end

  defp apply_filter_query_result(state, tab_id, where_clause, order_by_clause, result) do
    target_tab = Enum.find(state.tabs, &(&1.id == tab_id))
    old_grid = (target_tab && target_tab.datagrid_state) || state.datagrid_state

    case result do
      {:ok, %{columns: cols, rows: rows}} ->
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

        state
        |> update_tab_by_id(tab_id, fn tab -> %{tab | datagrid_state: grid} end)
        |> Map.put(
          :status_message,
          "Filter applied (#{length(rows)} rows): #{where_clause} #{order_by_clause}"
        )

      {:error, reason} ->
        msg = Strata.Formatter.format_error(reason)
        %{state | status_message: "❌ Filter SQL error: #{msg}"}
    end
  end

  defp apply_table_chunk_loaded(state, tab_id, table_name, result) do
    state = persist_active_tab(state)

    case Enum.find(state.tabs, &(&1.id == tab_id)) do
      %{kind: :table, table_name: ^table_name, datagrid_state: %DataGrid{} = grid} = tab ->
        case result do
          {:ok, _cols, new_rows} ->
            has_more = length(new_rows) == (grid.batch_size || 100)
            updated_grid = DataGrid.append_rows(grid, new_rows, has_more)

            if profile =
                 resolve_profile_by_id(tab.profile_id) ||
                   Sidebar.resolve_profile_for_selection(state) do
              Strata.DataStore.append_table_cache(
                profile.id,
                tab.schema,
                table_name,
                new_rows,
                has_more
              )
            end

            status_msg =
              "Loaded +#{length(new_rows)} rows for '#{table_name}' (Total: #{length(updated_grid.rows)} rows)"

            state
            |> update_tab_by_id(tab_id, fn t -> %{t | datagrid_state: updated_grid} end)
            |> Map.put(:status_message, status_msg)

          {:error, reason} ->
            status_msg =
              "Error loading more rows for '#{table_name}': #{Strata.Formatter.format_error(reason)}"

            state
            |> update_tab_by_id(tab_id, fn t ->
              %{t | datagrid_state: %{t.datagrid_state | loading_more: false}}
            end)
            |> Map.put(:status_message, status_msg)
        end

      _ ->
        state
    end
  end

  defp apply_sql_query_result(state, tab_id, elapsed, result) do
    case result do
      {:ok, %{columns: cols, rows: rows} = res_map} ->
        has_more? = Map.get(res_map, :has_more, false)

        grid =
          DataGrid.new(cols, rows,
            has_more: has_more?,
            loading_more: false,
            batch_size: 100
          )

        more_hint = if has_more?, do: "+", else: ""

        state
        |> update_tab_by_id(tab_id, fn tab ->
          %{tab | datagrid_state: grid, last_query_error: nil}
        end)
        |> Map.put(
          :status_message,
          "⚡ Query executed successfully (#{length(rows)}#{more_hint} rows in #{elapsed}ms)"
        )

      {:error, reason} ->
        msg = Strata.Formatter.format_error(reason)
        err_grid = DataGrid.new(["error"], [[msg]], has_more: false, loading_more: false)

        state
        |> update_tab_by_id(tab_id, fn tab ->
          %{tab | datagrid_state: err_grid, last_query_error: msg}
        end)
        |> Map.put(:status_message, "❌ SQL Error: #{msg}")
    end
  end

  defp apply_query_chunk_loaded(state, tab_id, req_id, result) do
    state = persist_active_tab(state)

    case Enum.find(state.tabs, &(&1.id == tab_id)) do
      %{kind: :query, datagrid_state: %DataGrid{} = grid} = tab ->
        if req_id != nil and Map.get(tab, :query_request_id) not in [nil, req_id] do
          state
        else
          case result do
            {:ok, %{rows: new_rows, has_more: has_more}} ->
              updated_grid = DataGrid.append_rows(grid, new_rows, has_more)

              state
              |> update_tab_by_id(tab_id, fn t -> %{t | datagrid_state: updated_grid} end)
              |> Map.put(
                :status_message,
                "Loaded +#{length(new_rows)} rows (Total: #{length(updated_grid.rows)} rows)"
              )

            {:error, reason} ->
              msg = Strata.Formatter.format_error(reason)

              state
              |> update_tab_by_id(tab_id, fn t ->
                %{t | datagrid_state: %{t.datagrid_state | loading_more: false}}
              end)
              |> Map.put(:status_message, "Error loading more query rows: #{msg}")
          end
        end

      _ ->
        state
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
    flush_workspace(state)

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

    alt? = "alt" in modifiers or "Alt" in modifiers
    shift? = "shift" in modifiers or "Shift" in modifiers

    cond do
      ctrl? and code in ["enter", "Enter"] ->
        {:ctrl, "enter"}

      shift? and code in ["enter", "Enter"] ->
        :shift_enter

      alt? and code in ["enter", "Enter"] ->
        :alt_enter

      ctrl? and code in ["left", "Left"] ->
        {:ctrl, :left}

      ctrl? and code in ["right", "Right"] ->
        {:ctrl, :right}

      ctrl? and code in [" ", "space", "Space"] ->
        {:ctrl, "space"}

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

      code in ["f4", "F4"] ->
        :f4

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
    nodes = Sidebar.load_nodes()

    first_id =
      case List.first(nodes) do
        nil -> nil
        n -> n.id
      end

    explicit_tabs? = Keyword.has_key?(opts, :tabs)

    has_table_opts? =
      Keyword.get(opts, :selected_table) != nil or
        (Keyword.get(opts, :active_view) == :table_view and
           Keyword.has_key?(opts, :datagrid_state))

    {initial_tabs, initial_active_id, initial_view} =
      if explicit_tabs? do
        t_list = Keyword.get(opts, :tabs, [])
        a_id = Keyword.get(opts, :active_tab_id) || (List.first(t_list) && List.first(t_list).id)
        v = Keyword.get(opts, :active_view, :query_view)
        {t_list, a_id, v}
      else
        if has_table_opts? do
          tbl = Keyword.get(opts, :selected_table)

          t =
            build_table_tab("tab_1", tbl || "Table",
              table_name: tbl,
              schema: Keyword.get(opts, :selected_schema),
              datagrid_state: Keyword.get(opts, :datagrid_state, DataGrid.new([], [])),
              active_filter: Keyword.get(opts, :active_filter),
              inspector_open: Keyword.get(opts, :inspector_open, false)
            )

          {[t], "tab_1", :table_view}
        else
          q =
            build_query_tab("tab_1", "Query 1",
              datagrid_state: Keyword.get(opts, :datagrid_state),
              inspector_open: Keyword.get(opts, :inspector_open, false)
            )

          {[q], "tab_1", Keyword.get(opts, :active_view, :query_view)}
        end
      end

    base = %__MODULE__{
      active_view: initial_view,
      selected_table: Keyword.get(opts, :selected_table),
      selected_schema: Keyword.get(opts, :selected_schema),
      datagrid_state: Keyword.get(opts, :datagrid_state),
      tabs: initial_tabs,
      active_tab_id: initial_active_id,
      sidebar_nodes: nodes,
      selected_tree_node_id: first_id
    }

    struct(base, opts)
  end

  @doc """
  Cycles focus between main layout panes (:sidebar -> :editor -> :datagrid).
  On `:table` tabs, cycles between :sidebar and :datagrid.
  """
  @spec cycle_focus(t(), :next | :prev) :: t()
  def cycle_focus(%__MODULE__{focus: current, active_view: active_view} = app, direction \\ :next) do
    panes =
      cond do
        active_view == :table_view -> [:sidebar, :datagrid]
        app.ai_panel_open -> [:sidebar, :editor, :datagrid, :ai_panel]
        true -> @panes
      end

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
  Switches active workspace view by focusing an existing `:table` or `:query` tab
  (opening a new SQL Query tab when switching to `:query_view` with none open).
  """
  @spec switch_view(t(), :table_view | :query_view) :: t()
  def switch_view(%__MODULE__{} = app, :table_view) do
    app = persist_active_tab(app)

    case Enum.find(app.tabs, &(Map.get(&1, :kind, :query) == :table)) do
      %{} = table_tab ->
        app
        |> hydrate_tab(table_tab)
        |> then(fn s -> if s.focus == :editor, do: %{s | focus: :datagrid}, else: s end)

      nil ->
        new_focus = if app.focus == :editor, do: :datagrid, else: app.focus
        %{app | active_view: :table_view, focus: new_focus}
    end
  end

  def switch_view(%__MODULE__{} = app, :query_view) do
    app = persist_active_tab(app)

    case active_tab(app) do
      %{kind: :query} ->
        %{app | active_view: :query_view, focus: :editor}

      _ ->
        case Enum.find(app.tabs, &(Map.get(&1, :kind, :query) == :query)) do
          %{} = query_tab ->
            app
            |> hydrate_tab(query_tab)
            |> Map.put(:focus, :editor)

          nil ->
            open_tab(app)
        end
    end
  end

  def switch_view(app, _invalid_view), do: app

  @doc """
  Sets active focus pane if valid.
  """
  @spec set_focus(t(), atom()) :: t()
  def set_focus(%__MODULE__{} = app, pane)
      when pane in [:sidebar, :editor, :datagrid, :ai_panel] do
    %{app | focus: pane}
  end

  def set_focus(%__MODULE__{} = app, _invalid_pane), do: app

  @doc """
  Opens a table in its own `:table` tab (or focuses the existing tab if that
  `{profile_id, schema, table_name}` is already open unless `refresh: true` or
  `new_tab: true`), serving from ETS cache or loading asynchronously.
  """
  @spec load_table_async(t(), String.t(), keyword()) :: t()
  def load_table_async(%__MODULE__{} = app, table_name, opts \\ []) when is_binary(table_name) do
    app = persist_active_tab(app)
    {profile, schema} = Sidebar.resolve_selection_context(app)
    profile_id = profile && profile.id
    refresh? = Keyword.get(opts, :refresh, false)
    new_tab? = Keyword.get(opts, :new_tab, false)

    existing =
      unless new_tab? do
        find_table_tab(app.tabs, profile_id, schema, table_name)
      end

    if existing != nil and not refresh? do
      app
      |> hydrate_tab(existing)
      |> set_focus(:datagrid)
      |> Map.put(:status_message, "Switched to tab '#{existing.name}'")
    else
      {app, tab_id} =
        if existing != nil do
          {hydrate_tab(app, existing), existing.id}
        else
          id = next_tab_id(app.tabs)

          new_tab =
            build_table_tab(id, table_name,
              table_name: table_name,
              schema: schema,
              profile_id: profile_id
            )

          {%{app | tabs: app.tabs ++ [new_tab]} |> hydrate_tab(new_tab), id}
        end

      req_id = System.unique_integer([:positive])

      cond do
        is_nil(profile) ->
          grid = DataGrid.new(["info"], [["No database connection configured"]], has_more: false)

          app
          |> update_tab_by_id(tab_id, fn t ->
            %{t | table_request_id: req_id, datagrid_state: grid}
          end)
          |> set_focus(:datagrid)
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
          |> update_tab_by_id(tab_id, fn t ->
            %{t | table_request_id: req_id, datagrid_state: grid}
          end)
          |> set_focus(:datagrid)
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
          |> update_tab_by_id(tab_id, fn t ->
            %{
              t
              | table_request_id: req_id,
                datagrid_state: loading_grid,
                structure_restore_grid: nil,
                active_filter: nil,
                filter_bar_open: false,
                filter_bar_focused: false,
                filter_bar_transient: false,
                filter_bar_focus_part: :value,
                filter_bar_col: "* All",
                filter_bar_op: :contains,
                filter_bar_text: "",
                filter_dropdown: nil,
                filter_dropdown_idx: 0,
                filter_dropdown_search: ""
            }
          end)
          |> set_focus(:datagrid)
          |> Map.put(:inline_input_ref, nil)
          |> Map.put(:status_message, "⏳ Loading table '#{table_name}'...")
          |> start_throbber_timer()
      end
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

  defp test_ai_cli_async(%__MODULE__{modals: [%AISettingsModal{} = am | rest]} = state) do
    settings = AISettingsModal.to_settings(am)
    caller = self()

    Task.start(fn ->
      res = Strata.AI.Client.test_cli(settings)
      send(caller, {:ai_cli_test_finished, res})
    end)

    updated_am = %{
      am
      | status: :testing,
        status_message: "⏳ Testing #{Strata.AISettings.cli_command(settings.provider)} CLI..."
    }

    %{state | modals: [updated_am | rest]}
  end

  defp test_ai_cli_async(state), do: state

  defp maybe_start_background_update_check(state) do
    if @env != :test and Map.get(state, :terminal, false) and
         System.get_env("STRATA_CHECK_UPDATES") != "false" do
      caller = self()

      Task.start(fn ->
        res = Strata.Updater.check_for_update()
        send(caller, {:startup_update_check_finished, res})
      end)
    end
  end

  @doc """
  Opens the App Update modal and automatically triggers a check if no cached check exists.
  """
  @spec open_update_modal(t()) :: t()
  def open_update_modal(%__MODULE__{} = app) do
    modal = UpdateModal.new(update_info: app.update_info)
    app_with_modal = push_modal(app, modal)

    if app.update_info == nil do
      check_updates_async(app_with_modal)
    else
      app_with_modal
    end
  end

  @doc """
  Starts an asynchronous update check when `%UpdateModal{}` is the active top modal.
  """
  @spec check_updates_async(t(), keyword()) :: t()
  def check_updates_async(state, opts \\ [])

  def check_updates_async(%__MODULE__{modals: [%UpdateModal{} = um | rest]} = state, opts) do
    caller = self()

    Task.start(fn ->
      res = Strata.Updater.check_for_update(opts)
      send(caller, {:update_check_finished, res})
    end)

    updated_um = %{
      um
      | status: :checking,
        status_message: "⏳ Checking GitHub Releases for updates..."
    }

    %{state | modals: [updated_um | rest]}
  end

  def check_updates_async(state, _opts), do: state

  @doc """
  Starts an asynchronous self-update download and binary replacement when `%UpdateModal{}` is active.
  """
  @spec install_update_async(t(), keyword()) :: t()
  def install_update_async(state, opts \\ [])

  def install_update_async(%__MODULE__{modals: [%UpdateModal{} = um | rest]} = state, opts) do
    case um.update_info do
      %{status: :update_available} = info ->
        caller = self()

        Task.start(fn ->
          res = Strata.Updater.apply_update(info, opts)
          send(caller, {:update_install_finished, res})
        end)

        updated_um = %{
          um
          | status: :updating,
            status_message: "⏳ Downloading and installing v#{info.latest_version}..."
        }

        %{state | modals: [updated_um | rest]}

      _ ->
        updated_um = %{
          um
          | status: :error,
            status_message: "❌ No available update to install. Check for updates first."
        }

        %{state | modals: [updated_um | rest]}
    end
  end

  def install_update_async(state, _opts), do: state

  @doc """
  Opens the AI Assistant Settings modal.
  """
  @spec open_ai_settings_modal(t()) :: t()
  def open_ai_settings_modal(%__MODULE__{} = app) do
    push_modal(app, AISettingsModal.new())
  end

  @doc """
  Opens or toggles the Right AI Chat Panel for the active SQL tab.
  - When closed (or in `:table_view`), switches to `:query_view`, opens the panel, and focuses input.
  - When already open and focused elsewhere, moves focus to the AI input box.
  - When already open and focused in `:ai_panel`, closes the panel and returns focus to `:editor`.
  """
  @spec open_ai_sql_prompt(t()) :: t()
  def open_ai_sql_prompt(%__MODULE__{} = app) do
    cond do
      active_tab_kind(app) != :query ->
        app
        |> open_tab()
        |> Map.put(:ai_panel_open, true)
        |> Map.put(:ai_panel_focus, :input)
        |> Map.put(:focus, :ai_panel)
        |> sync_ai_panel_scroll_to_bottom()

      not app.ai_panel_open ->
        app
        |> persist_active_tab()
        |> Map.put(:ai_panel_open, true)
        |> Map.put(:ai_panel_focus, :input)
        |> Map.put(:focus, :ai_panel)
        |> sync_ai_panel_scroll_to_bottom()
        |> save_workspace_async()

      app.focus != :ai_panel ->
        %{app | ai_panel_focus: :input, focus: :ai_panel}

      true ->
        %{app | ai_panel_open: false, focus: :editor}
        |> save_workspace_async()
    end
  end

  @doc """
  Submits the current `ai_input_text` inside the Right AI Chat Panel, expanding any collapsed paste pills.
  """
  @spec submit_ai_chat_input(t(), keyword()) :: t()
  def submit_ai_chat_input(%__MODULE__{} = app, opts \\ []) do
    display_prompt = String.trim(to_string(app.ai_input_text || ""))

    if display_prompt == "" do
      %{app | status_message: "⚠️ Enter a question or instruction for AI first"}
    else
      expanded_prompt = AIChatPanel.expand_pastes(display_prompt, app.ai_pastes || %{})

      cleared = %{
        app
        | ai_input_text: "",
          ai_input_cursor: 0,
          ai_pastes: %{},
          ai_paste_seq: 0
      }

      start_ai_sql_task(
        cleared,
        display_prompt,
        Keyword.put(opts, :expanded_prompt, expanded_prompt)
      )
    end
  end

  @doc """
  Applies the SQL generated in turn `msg_idx` of the active tab's `ai_messages` back into the SQL Editor.
  """
  @spec apply_ai_history_turn(t(), non_neg_integer()) :: t()
  def apply_ai_history_turn(%__MODULE__{} = app, msg_idx) when is_integer(msg_idx) do
    app = persist_active_tab(app)
    tab = active_tab(app)
    messages = (tab && Map.get(tab, :ai_messages, [])) || []

    case Enum.at(messages, msg_idx) do
      %{status: :done, sql: sql, id: msg_id} = msg when is_binary(sql) and sql != "" ->
        app =
          update_tab_by_id(app, tab.id, fn t ->
            %{
              t
              | content: sql,
                cursor: {0, 0},
                scroll_offset: 0,
                diagnostics: [],
                ai_applied_msg_id: msg_id,
                last_query_error: nil
            }
          end)

        app =
          case Enum.find(app.tabs, &(&1.id == tab.id)) do
            nil -> app
            updated_tab -> hydrate_tab(app, updated_tab)
          end

        save_workspace_async(app)

        warn =
          if Map.get(msg, :is_read_only, true),
            do: "✨ Applied AI turn ##{msg_idx + 1} to SQL Editor",
            else: "⚠️ Applied WRITE/DDL turn ##{msg_idx + 1} — review before running!"

        %{app | ai_selected_msg_idx: msg_idx, status_message: warn}

      %{status: :running} ->
        %{app | status_message: "⏳ AI turn ##{msg_idx + 1} is still running..."}

      _ ->
        %{app | status_message: "⚠️ Selected AI turn has no SQL to apply"}
    end
  end

  @doc """
  Clears the active tab's AI session ID and chat history.
  """
  @spec reset_ai_tab_conversation(t()) :: t()
  def reset_ai_tab_conversation(%__MODULE__{} = app) do
    app = cancel_ai_request(app)

    app =
      if app.active_tab_id do
        update_tab_by_id(app, app.active_tab_id, fn t ->
          Map.merge(t, %{
            ai_session_id: nil,
            ai_messages: [],
            ai_applied_msg_id: nil
          })
        end)
      else
        app
      end

    save_workspace_async(app)

    %{
      app
      | ai_selected_msg_idx: nil,
        ai_history_scroll: 0,
        ai_panel_focus: :input,
        status_message: "↺ Reset AI conversation for active tab"
    }
  end

  defp start_ai_sql_task(app, display_prompt, opts \\ []) do
    settings = Strata.AISettingsStore.get()
    context = Strata.AI.ContextBuilder.build(app, settings)
    tab = active_tab(app)
    tab_id = tab && tab.id
    session_id = tab && Map.get(tab, :ai_session_id)
    msg_id = "ai_" <> Integer.to_string(System.unique_integer([:positive]))
    ai_prompt = Keyword.get(opts, :expanded_prompt, display_prompt)

    pending_msg = %{
      id: msg_id,
      prompt: display_prompt,
      sql: nil,
      is_read_only: true,
      explanation: nil,
      error: nil,
      status: :running
    }

    app =
      if tab_id do
        update_tab_by_id(app, tab_id, fn t ->
          msgs = Map.get(t, :ai_messages, []) ++ [pending_msg]
          %{t | ai_messages: msgs}
        end)
      else
        app
      end

    req_id = make_ref()
    caller = self()
    client_opts = Keyword.merge([session_id: session_id], Keyword.delete(opts, :expanded_prompt))

    {:ok, pid} =
      Task.start(fn ->
        res = Strata.AI.Client.generate_sql(settings, context, ai_prompt, client_opts)
        send(caller, {:ai_task_finished, req_id, :sql, tab_id, msg_id, res})
      end)

    provider_name = Strata.AISettings.cli_command(settings.provider)
    updated_tab = Enum.find(app.tabs, &(&1.id == tab_id))

    new_sel_idx =
      max(0, length((updated_tab && Map.get(updated_tab, :ai_messages, [])) || []) - 1)

    %{
      app
      | ai_request: %{id: req_id, pid: pid, tab_id: tab_id, msg_id: msg_id},
        ai_selected_msg_idx: new_sel_idx,
        status_message: "⏳ Asking #{provider_name} AI..."
    }
    |> sync_ai_panel_scroll_to_bottom()
    |> start_throbber_timer()
  end

  defp cancel_ai_request(
         %__MODULE__{ai_request: %{pid: pid, tab_id: tab_id, msg_id: msg_id}} = app
       ) do
    if is_pid(pid) and Process.alive?(pid) do
      Process.exit(pid, :kill)
    end

    app =
      if tab_id do
        update_tab_by_id(app, tab_id, fn t ->
          msgs =
            Map.get(t, :ai_messages, [])
            |> Enum.map(fn m ->
              if Map.get(m, :id) == msg_id and Map.get(m, :status) == :running do
                %{m | status: :error, error: "Cancelled"}
              else
                m
              end
            end)

          %{t | ai_messages: msgs}
        end)
      else
        app
      end

    %{app | ai_request: nil, status_message: "Cancelled AI request"}
    |> cancel_throbber_timer()
  end

  defp cancel_ai_request(app), do: app

  defp apply_ai_task_result(app, tab_id, msg_id, {:error, msg}) do
    err_text = Strata.Formatter.format_error(msg)

    app =
      if tab_id do
        update_tab_by_id(app, tab_id, fn t ->
          msgs =
            Map.get(t, :ai_messages, [])
            |> Enum.map(fn m ->
              if Map.get(m, :id) == msg_id do
                %{m | status: :error, error: err_text}
              else
                m
              end
            end)

          %{t | ai_messages: msgs}
        end)
      else
        app
      end

    save_workspace_sync(app)

    %{app | status_message: "❌ AI error: #{err_text}"}
    |> sync_ai_panel_scroll_to_bottom()
  end

  defp apply_ai_task_result(app, tab_id, msg_id, {:ok, res}) do
    sql = to_string(res.sql || "")
    session_id = res.session_id

    target_id =
      cond do
        is_binary(tab_id) and Enum.any?(app.tabs, &(&1.id == tab_id and &1.kind == :query)) ->
          tab_id

        active_tab_kind(app) == :query ->
          app.active_tab_id

        true ->
          nil
      end

    app =
      if target_id do
        update_tab_by_id(app, target_id, fn t ->
          msgs =
            Map.get(t, :ai_messages, [])
            |> Enum.map(fn m ->
              if Map.get(m, :id) == msg_id do
                %{
                  m
                  | status: :done,
                    sql: sql,
                    is_read_only: res.is_read_only,
                    explanation: res.explanation,
                    error: nil
                }
              else
                m
              end
            end)

          %{
            t
            | content: sql,
              cursor: {0, 0},
              scroll_offset: 0,
              diagnostics: [],
              ai_session_id: session_id || Map.get(t, :ai_session_id),
              ai_applied_msg_id: msg_id,
              ai_messages: msgs,
              last_query_error: nil
          }
        end)
      else
        opened = open_tab(app, content: sql)

        if opened.active_tab_id do
          update_tab_by_id(opened, opened.active_tab_id, fn t ->
            %{t | ai_session_id: session_id, ai_applied_msg_id: msg_id}
          end)
        else
          opened
        end
      end

    app =
      case Enum.find(app.tabs, &(&1.id == (target_id || app.active_tab_id))) do
        nil -> app
        tab -> hydrate_tab(app, tab)
      end

    save_workspace_sync(app)

    status_msg =
      if res.is_read_only do
        "✨ AI SQL ready (#{res.explanation}) — Ctrl+Enter to Run"
      else
        "⚠️ AI SQL ready (WRITE/DDL — review carefully!): #{res.explanation}"
      end

    %{app | status_message: status_msg}
    |> sync_ai_panel_scroll_to_bottom()
  end

  defp sync_ai_panel_scroll_to_bottom(app) do
    areas = Renderer.layout_for(app)

    case Map.get(areas, :ai_panel) do
      %{} = ai_area ->
        %{history_area: hist_area} = AIChatPanel.areas(ai_area)
        tab = active_tab(app)
        data = AIChatPanel.history_data(app, tab, hist_area)
        msgs = (tab && Map.get(tab, :ai_messages, [])) || []

        %{
          app
          | ai_history_scroll: data.max_scroll,
            ai_selected_msg_idx: if(msgs == [], do: nil, else: length(msgs) - 1)
        }

      nil ->
        app
    end
  end

  defp restore_workspace_tabs(app) do
    case Strata.WorkspaceStore.load() do
      %{tabs: saved_tabs, active_tab_id: saved_active_id} = ws ->
        closed = Map.get(ws, :closed_tabs, [])
        ai_open? = Map.get(ws, :ai_panel_open, false) == true

        if is_list(saved_tabs) and saved_tabs != [] do
          restored =
            Enum.map(saved_tabs, fn t ->
              build_query_tab(t.id, t.name,
                profile_id: t.profile_id,
                content: t.content,
                cursor: t.cursor,
                ai_session_id: t.ai_session_id,
                ai_applied_msg_id: t.ai_applied_msg_id,
                ai_messages: t.ai_messages
              )
            end)

          target_tab =
            Enum.find(restored, &(&1.id == saved_active_id)) || List.first(restored)

          restored_app =
            %{app | tabs: restored, closed_tabs: closed, ai_panel_open: ai_open?}
            |> hydrate_tab(target_tab)

          {restored_app, true}
        else
          {%{app | closed_tabs: closed, ai_panel_open: ai_open?}, false}
        end

      _ ->
        {app, false}
    end
  end

  defp save_workspace_async(app) do
    if Process.whereis(Strata.WorkspaceStore) do
      persisted = persist_active_tab(app)

      Strata.WorkspaceStore.save(
        persisted.tabs,
        persisted.active_tab_id,
        app.closed_tabs,
        ai_panel_open: app.ai_panel_open
      )
    end

    app
  end

  defp save_workspace_sync(app) do
    flush_workspace(app)
    app
  end

  defp flush_workspace(app) do
    if Process.whereis(Strata.WorkspaceStore) do
      persisted = persist_active_tab(app)

      Strata.WorkspaceStore.save_sync(
        persisted.tabs,
        persisted.active_tab_id,
        app.closed_tabs,
        ai_panel_open: app.ai_panel_open
      )
    end

    :ok
  end

  @doc """
  Opens a new blank SQL tab immediately if `closed_tabs` is empty, or pushes
  `SQLTabPickerModal` so the user can choose between a new blank tab or reopening a closed tab.
  """
  @spec request_new_sql_tab(t()) :: t()
  def request_new_sql_tab(%__MODULE__{closed_tabs: []} = app), do: open_tab(app)

  def request_new_sql_tab(%__MODULE__{closed_tabs: closed} = app) when is_list(closed) do
    push_modal(app, SQLTabPickerModal.new(closed))
  end

  @doc """
  Reopens a previously closed SQL tab entry (restoring SQL content, cursor, and AI chat history)
  and removes it from `closed_tabs`.
  """
  @spec reopen_closed_tab(t(), map()) :: t()
  def reopen_closed_tab(%__MODULE__{} = app, closed_tab) when is_map(closed_tab) do
    closed_id = Map.get(closed_tab, :id)
    remaining_closed = Enum.reject(app.closed_tabs || [], &(Map.get(&1, :id) == closed_id))
    ai_messages = Map.get(closed_tab, :ai_messages, [])

    reopened =
      %{app | closed_tabs: remaining_closed}
      |> open_tab(
        name: Map.get(closed_tab, :name),
        profile_id: Map.get(closed_tab, :profile_id),
        content: Map.get(closed_tab, :content, ""),
        cursor: Map.get(closed_tab, :cursor, {0, 0}),
        ai_session_id: Map.get(closed_tab, :ai_session_id),
        ai_applied_msg_id: Map.get(closed_tab, :ai_applied_msg_id),
        ai_messages: ai_messages
      )

    reopened =
      if ai_messages != [] do
        %{reopened | ai_panel_open: true}
        |> sync_ai_panel_scroll_to_bottom()
      else
        reopened
      end

    reopened
    |> Map.put(:status_message, "↺ Reopened SQL tab '#{Map.get(closed_tab, :name, "Query")}'")
    |> save_workspace_sync()
  end

  @doc """
  Invalidates cache and reloads the currently selected table.
  Prompts with `ConfirmModal` when uncommitted edits are present unless `force: true`.
  """
  @spec refresh_active_table(t(), keyword()) :: t()
  def refresh_active_table(app, opts \\ [])

  def refresh_active_table(%__MODULE__{active_view: :table_view, selected_table: tbl} = app, opts)
      when is_binary(tbl) do
    force? = Keyword.get(opts, :force, false)
    tab = active_tab(app)
    {staged_count, inline_editing?} = dirty_state_for_tab(app, tab)

    if not force? and (staged_count > 0 or inline_editing?) do
      modal =
        ConfirmModal.new(
          kind: :refresh_dirty_table,
          tab_id: tab && tab.id,
          tab_name: tbl,
          dirty_count: staged_count,
          inline_editing?: inline_editing?,
          can_commit?: true,
          focused_field: :cancel_button
        )

      push_modal(app, modal)
    else
      load_table_async(app, tbl, refresh: true)
    end
  end

  def refresh_active_table(app, _opts), do: app

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
      tab = active_tab(app)
      profile = resolve_tab_profile(app, tab)
      schema = (tab && Map.get(tab, :schema)) || app.selected_schema

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

            tab_id = (tab && tab.id) || app.active_tab_id

            app
            |> update_tab_by_id(tab_id, fn t ->
              %{
                t
                | table_request_id: req_id,
                  datagrid_state: loading_grid,
                  structure_restore_grid: grid
              }
            end)
            |> Map.put(:inline_input_ref, nil)
            |> Map.put(:status_message, "⏳ Inspecting structure of '#{tbl}'...")
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
      dirty_grid?(grid) ->
        %{app | status_message: "⚠️ Commit (Ctrl+S) or Revert (Ctrl+Z) changes before sorting"}

      true ->
        case Enum.at(grid.columns, col_idx) do
          nil ->
            app

          col_name ->
            col_str = to_string(col_name)
            sorted_grid = DataGrid.cycle_sort(grid, col_str)
            tab = active_tab(app)
            profile = resolve_tab_profile(app, tab)
            schema = (tab && Map.get(tab, :schema)) || app.selected_schema

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

              tab_id = (tab && tab.id) || app.active_tab_id

              app
              |> update_tab_by_id(tab_id, fn t ->
                %{
                  t
                  | table_request_id: req_id,
                    datagrid_state: %{sorted_grid | loading_more: true}
                }
              end)
              |> Map.put(:status_message, "⏳ Sorting '#{tbl}' by #{col_str}...")
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
  Opens and focuses the Unified Filter & Sort Bar.
  Supports `:all_columns` (`/`), `:focus`, `:dropdown`, and `:transient`.
  """
  @spec open_filter_bar(t(), keyword()) :: t()
  def open_filter_bar(app, opts \\ [])

  def open_filter_bar(%__MODULE__{datagrid_state: %DataGrid{} = grid} = app, opts) do
    all_cols? = Keyword.get(opts, :all_columns, false)
    explicit_focus = Keyword.get(opts, :focus)
    explicit_dropdown = Keyword.get(opts, :dropdown)
    transient? = Keyword.get(opts, :transient, false)

    {_r, c} = grid.selected_cell
    selected_col = Enum.at(grid.columns, c)

    {col, op, initial_text} =
      cond do
        all_cols? ->
          {"* All", :contains, ""}

        is_map(app.active_filter) ->
          af = app.active_filter
          {Map.get(af, :column, "* All"), Map.get(af, :op, :contains), Map.get(af, :value, "")}

        grid.mode == :selecting and grid.view_mode == :data and is_binary(selected_col) ->
          {selected_col, :contains, app.filter_bar_text || ""}

        true ->
          {app.filter_bar_col || "* All", app.filter_bar_op || :contains,
           app.filter_bar_text || ""}
      end

    ref = app.filter_bar_ref || ExRatatui.text_input_new()
    ExRatatui.text_input_set_value(ref, to_string(initial_text))

    focus_part =
      explicit_focus ||
        if(op in [:is_null, :is_not_null], do: :op, else: :value)

    dropdown_idx =
      if explicit_dropdown == :sort do
        case grid.sort_by do
          {sort_col, _dir} -> Enum.find_index(grid.columns, &(to_string(&1) == sort_col)) || 0
          _ -> 0
        end
      else
        0
      end

    status_msg =
      if explicit_dropdown == :sort do
        "↕ Pick column to sort (↑/↓ Enter · type to search · Tab Filter · Esc close)"
      else
        "🔍 Filter & Sort: type value & Enter · Tab Col/Op/Sort · Ctrl+G SQL Tab · Ctrl+L Reset"
      end

    %{
      app
      | focus: :datagrid,
        filter_bar_open: true,
        filter_bar_focused: true,
        filter_bar_transient: transient?,
        filter_bar_focus_part: focus_part,
        filter_bar_col: col,
        filter_bar_op: op,
        filter_bar_ref: ref,
        filter_bar_text: to_string(initial_text),
        filter_history_idx: nil,
        filter_history_draft: nil,
        filter_dropdown: explicit_dropdown,
        filter_dropdown_idx: dropdown_idx,
        filter_dropdown_search: "",
        status_message: status_msg
    }
  end

  def open_filter_bar(app, _opts), do: app

  @doc """
  Opens a new SQL Editor tab pre-filled with a `SELECT` query matching the active table,
  active filter (if any), and active sort so complex queries can be edited with full SQL tools.
  """
  @spec open_table_in_sql_editor(t()) :: t()
  def open_table_in_sql_editor(%__MODULE__{selected_table: tbl} = app)
      when is_binary(tbl) and tbl != "" do
    tab = active_tab(app)
    profile = resolve_tab_profile(app, tab)
    driver = (profile && profile.driver) || :postgres
    schema = (tab && Map.get(tab, :schema)) || app.selected_schema
    grid = app.datagrid_state || DataGrid.new()
    qualified = Sidebar.qualify_table(driver, tbl, schema)

    filter_spec =
      cond do
        is_map(app.active_filter) ->
          app.active_filter

        app.filter_bar_open and
            (String.trim(app.filter_bar_text || "") != "" or
               app.filter_bar_op in [:is_null, :is_not_null]) ->
          %{
            mode: :builder,
            column: app.filter_bar_col || "* All",
            op: app.filter_bar_op || :contains,
            value: app.filter_bar_text || ""
          }

        true ->
          nil
      end

    sql = build_editable_table_sql(driver, qualified, grid, filter_spec)

    app
    |> collapse_transient_filter_bar()
    |> open_tab(content: sql, profile_id: profile && profile.id)
    |> Map.put(:status_message, "Opened '#{tbl}' query in SQL Editor")
  end

  def open_table_in_sql_editor(app), do: open_tab(app)

  defp build_editable_table_sql(driver, qualified, grid, nil) do
    order_sql =
      case grid.sort_by do
        {col, dir} when is_binary(col) and dir in [:asc, :desc] ->
          "\nORDER BY #{Strata.Adapter.quote_identifier(driver, col)} #{if dir == :asc, do: "ASC", else: "DESC"}"

        _ ->
          ""
      end

    "SELECT *\nFROM #{qualified}#{order_sql}\nLIMIT 200;"
  end

  defp build_editable_table_sql(driver, qualified, grid, filter_spec) do
    sample_row = List.first(grid.rows) || []

    case Strata.QueryBuilder.build_filter_select(
           driver,
           qualified,
           grid.columns,
           filter_spec,
           order_by: grid.sort_by,
           sample_row: sample_row
         ) do
      {:ok, {sql, params}} ->
        inline_sql_params(driver, sql, params)

      {:error, _} ->
        build_editable_table_sql(driver, qualified, grid, nil)
    end
  end

  defp inline_sql_params(_driver, sql, []), do: sql

  defp inline_sql_params(driver, sql, params) do
    if Strata.Adapter.normalize_driver(driver) == :postgres do
      param_tuple = List.to_tuple(params)

      Regex.replace(~r/\$(\d+)\b/, sql, fn full, num_str ->
        idx = String.to_integer(num_str) - 1

        if idx >= 0 and idx < tuple_size(param_tuple) do
          format_sql_literal(elem(param_tuple, idx))
        else
          full
        end
      end)
    else
      [first | rest] = String.split(sql, "?")

      {acc, _remaining} =
        Enum.reduce(rest, {[first], params}, fn part, {chunks, rem_params} ->
          case rem_params do
            [val | tail] -> {[part, format_sql_literal(val) | chunks], tail}
            [] -> {[part, "?" | chunks], []}
          end
        end)

      acc |> Enum.reverse() |> IO.iodata_to_binary()
    end
  end

  defp format_sql_literal(nil), do: "NULL"
  defp format_sql_literal(val) when is_integer(val) or is_float(val), do: to_string(val)
  defp format_sql_literal(true), do: "TRUE"
  defp format_sql_literal(false), do: "FALSE"

  defp format_sql_literal(val) do
    "'" <> String.replace(to_string(val), "'", "''") <> "'"
  end

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
      |> Map.put(:filter_bar_transient, false)
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
  Handles key events when the Unified Filter & Sort Bar has focus.
  """
  @spec handle_filter_bar_key(t(), term()) :: t()
  def handle_filter_bar_key(%__MODULE__{filter_dropdown: kind} = app, key)
      when kind in [:column, :op, :sort] do
    handle_filter_dropdown_key(app, key)
  end

  def handle_filter_bar_key(%__MODULE__{} = app, key) do
    case key do
      {:ctrl, "l"} ->
        clear_table_filter(app)

      {:ctrl, "g"} ->
        open_table_in_sql_editor(app)

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
        if app.filter_bar_transient or
             (String.trim(app.filter_bar_text || "") == "" and is_nil(app.active_filter)) do
          %{
            app
            | filter_bar_open: false,
              filter_bar_focused: false,
              filter_bar_transient: false,
              filter_dropdown: nil
          }
        else
          %{app | filter_bar_focused: false, filter_bar_transient: false, filter_dropdown: nil}
        end

      other ->
        case app.filter_bar_focus_part do
          :column -> handle_filter_column_key(app, other)
          :op -> handle_filter_op_key(app, other)
          :sort -> handle_filter_sort_key(app, other)
          _ -> handle_filter_value_key(app, other)
        end
    end
  end

  defp open_filter_dropdown(app, kind) when kind in [:column, :op, :sort] do
    grid = app.datagrid_state || DataGrid.new()

    idx =
      case kind do
        :column ->
          cols = ["* All" | grid.columns || []]
          Enum.find_index(cols, &(&1 == app.filter_bar_col)) || 0

        :op ->
          ops = Strata.QueryBuilder.filter_operators()
          Enum.find_index(ops, &(&1 == app.filter_bar_op)) || 0

        :sort ->
          case grid.sort_by do
            {col, _dir} -> Enum.find_index(grid.columns || [], &(to_string(&1) == col)) || 0
            _ -> 0
          end
      end

    %{
      app
      | filter_bar_open: true,
        filter_bar_focused: true,
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
        if app.filter_bar_transient do
          %{
            app
            | filter_bar_open: false,
              filter_bar_focused: false,
              filter_bar_transient: false,
              filter_dropdown: nil,
              filter_dropdown_search: ""
          }
        else
          %{app | filter_dropdown: nil, filter_dropdown_search: ""}
        end

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

      :backspace when app.filter_dropdown in [:column, :sort] ->
        s = app.filter_dropdown_search || ""
        new_s = String.slice(s, 0, max(0, String.length(s) - 1))
        %{app | filter_dropdown_search: new_s, filter_dropdown_idx: 0}

      k when is_binary(k) and app.filter_dropdown in [:column, :sort] ->
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

  defp select_filter_dropdown_item(%{filter_dropdown: :sort} = app, nil) do
    base = %{app | filter_dropdown: nil, filter_dropdown_search: ""}

    if app.filter_bar_transient do
      %{base | filter_bar_open: false, filter_bar_focused: false, filter_bar_transient: false}
    else
      base
    end
  end

  defp select_filter_dropdown_item(app, nil) do
    %{app | filter_dropdown: nil, filter_dropdown_search: ""}
  end

  defp select_filter_dropdown_item(%{filter_dropdown: :column} = app, %{value: val}) do
    %{
      app
      | filter_bar_col: val,
        filter_bar_transient: false,
        filter_dropdown: nil,
        filter_dropdown_search: "",
        filter_bar_focus_part:
          if(app.filter_bar_op in [:is_null, :is_not_null], do: :op, else: :value)
    }
  end

  defp select_filter_dropdown_item(%{filter_dropdown: :op} = app, %{value: op}) do
    updated = %{
      app
      | filter_bar_op: op,
        filter_bar_transient: false,
        filter_dropdown: nil,
        filter_dropdown_search: ""
    }

    if op in [:is_null, :is_not_null] do
      apply_smart_filter(%{updated | filter_bar_focused: false, filter_bar_focus_part: :op})
    else
      %{updated | filter_bar_focus_part: :value}
    end
  end

  defp select_filter_dropdown_item(%{filter_dropdown: :sort} = app, %{kind: :clear}) do
    app
    |> Map.put(:filter_dropdown, nil)
    |> Map.put(:filter_dropdown_search, "")
    |> then(fn a ->
      if a.filter_bar_transient do
        %{a | filter_bar_open: false, filter_bar_focused: false, filter_bar_transient: false}
      else
        %{a | filter_bar_focus_part: :value}
      end
    end)
    |> execute_actions_modal_item(:clear_sort)
  end

  defp select_filter_dropdown_item(%{filter_dropdown: :sort} = app, %{
         kind: :column,
         col_idx: col_idx
       })
       when is_integer(col_idx) do
    app
    |> Map.put(:filter_dropdown, nil)
    |> Map.put(:filter_dropdown_search, "")
    |> then(fn a ->
      if a.filter_bar_transient do
        %{a | filter_bar_open: false, filter_bar_focused: false, filter_bar_transient: false}
      else
        %{a | filter_bar_focus_part: :value}
      end
    end)
    |> sort_active_table_by_col(col_idx)
  end

  defp cycle_filter_part(app, delta) do
    parts =
      if app.filter_bar_op in [:is_null, :is_not_null] do
        [:column, :op, :sort]
      else
        [:column, :op, :value, :sort]
      end

    idx = Enum.find_index(parts, &(&1 == app.filter_bar_focus_part)) || 0
    next = Enum.at(parts, rem(idx + delta + length(parts), length(parts)))
    %{app | filter_bar_focus_part: next, filter_bar_transient: false}
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

  defp handle_filter_sort_key(app, key) do
    case key do
      k when k in [:down, :up, :enter, :space] ->
        open_filter_dropdown(app, :sort)

      ch when is_binary(ch) ->
        if String.length(ch) == 1 do
          open_filter_dropdown(app, :sort)
          |> Map.put(:filter_dropdown_search, ch)
          |> Map.put(:filter_dropdown_idx, 0)
        else
          app
        end

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

        if trimmed == "" and app.filter_bar_op not in [:is_null, :is_not_null] do
          clear_table_filter(app)
        else
          app
          |> Map.put(:filter_bar_text, raw)
          |> Map.put(:filter_bar_focused, false)
          |> Map.put(:filter_bar_transient, false)
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

    if app.active_view == :table_view and is_binary(app.selected_table) and dirty_grid?(grid) do
      %{
        app
        | filter_bar_focused: false,
          status_message: "⚠️ Commit (Ctrl+S) or Revert (Ctrl+Z) changes before filtering"
      }
    else
      do_apply_smart_filter(app, grid)
    end
  end

  defp do_apply_smart_filter(app, grid) do
    col = app.filter_bar_col || "* All"
    op = app.filter_bar_op || :contains
    val = app.filter_bar_text || ""
    op_lbl = Strata.QueryBuilder.operator_label(op)

    summary =
      if op in [:is_null, :is_not_null],
        do: "#{col} #{op_lbl}",
        else: "#{col} #{op_lbl} #{val}"

    filter_spec = %{mode: :builder, column: col, op: op, value: val, summary: summary}

    tab = active_tab(app)
    tab_id = tab && tab.id
    table_name = app.selected_table
    profile = resolve_tab_profile(app, tab)
    schema = (tab && Map.get(tab, :schema)) || app.selected_schema

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
            send(caller, {:filter_query_finished, tab_id, filter_spec.summary, "", res})
          end)

          %{app | status_message: "⏳ Filtering: #{filter_spec.summary}..."}

        {:error, reason} ->
          %{app | status_message: "❌ Filter error: #{Strata.Formatter.format_error(reason)}"}
      end
    else
      %{app | status_message: "Filter applied: #{filter_spec.summary}"}
    end
  end

  defp push_filter_history(app, filter_spec) do
    text = String.trim(to_string(filter_spec[:value] || ""))
    op = filter_spec[:op] || :contains

    if text == "" and op not in [:is_null, :is_not_null] do
      app
    else
      table_key = app.selected_table || "__query__"

      entry = %{
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

    if had_active_filter? and app.active_view == :table_view and is_binary(app.selected_table) and
         dirty_grid?(app.datagrid_state) do
      %{
        app
        | filter_bar_focused: false,
          status_message: "⚠️ Commit (Ctrl+S) or Revert (Ctrl+Z) changes before clearing filter"
      }
    else
      if app.filter_bar_ref, do: ExRatatui.text_input_set_value(app.filter_bar_ref, "")

      base = %{
        app
        | active_filter: nil,
          filter_bar_open: false,
          filter_bar_focused: false,
          filter_bar_transient: false,
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
        |> refresh_active_table(force: true)
        |> Map.put(:status_message, "Filter cleared — showing full table")
      else
        %{base | status_message: "Filter bar closed"}
      end
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
    do: %{
      app
      | filter_bar_open: false,
        filter_bar_focused: false,
        filter_bar_transient: false,
        filter_dropdown: nil
    }

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
  Opens the Unified Filter & Sort Bar focused directly on the Sort column picker.
  """
  @spec open_sort_picker(t()) :: t()
  def open_sort_picker(%__MODULE__{datagrid_state: %DataGrid{columns: cols}} = app)
      when cols != [] do
    open_filter_bar(app,
      focus: :sort,
      dropdown: :sort,
      transient: not app.filter_bar_open
    )
  end

  def open_sort_picker(app), do: app

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

      app.focus == :ai_panel ->
        clean =
          text
          |> String.replace("\r\n", "\n")
          |> String.replace("\r", "\n")
          |> String.trim_trailing("\n")

        if AIChatPanel.long_paste?(clean) do
          seq = (app.ai_paste_seq || 0) + 1
          token = AIChatPanel.paste_pill_label(seq, clean)
          pastes = Map.put(app.ai_pastes || %{}, token, clean)

          %{app | ai_pastes: pastes, ai_paste_seq: seq}
          |> insert_ai_input_text(token)
        else
          insert_ai_input_text(app, clean)
        end

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
    tab = active_tab(app)
    profile = resolve_tab_profile(app, tab)
    schema = (tab && Map.get(tab, :schema)) || app.selected_schema
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
            %{
              app
              | status_message:
                  "❌ Cannot build commit SQL: #{Strata.Formatter.format_error(reason)}"
            }
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
        clear_active_sort(app)

      :toggle_select_mode ->
        next_mode = if grid.mode == :selecting, do: :browsing, else: :selecting

        msg =
          if next_mode == :selecting,
            do:
              "SELECT MODE: ↑/↓/←/→ move · [e] edit · [i] insert · [d] delete · [c] copy · [Esc] exit",
            else: "BROWSING MODE: Press [v] or click cell for Select Mode · [?] Actions"

        %{app | datagrid_state: %{grid | mode: next_mode}, status_message: msg}

      :sidebar_add_conn ->
        push_modal(app, ConnectionModal.new())

      :sidebar_edit_conn ->
        Sidebar.handle_key(%{app | focus: :sidebar}, "e")

      :sidebar_delete_conn ->
        Sidebar.handle_key(%{app | focus: :sidebar}, "d")

      :sidebar_refresh ->
        refresh_sidebar_selection(app)

      :sidebar_filter ->
        Sidebar.handle_key(%{app | focus: :sidebar}, "/")

      :sidebar_expand_all ->
        Sidebar.handle_key(app, "o")

      :sidebar_collapse_all ->
        Sidebar.handle_key(app, "c")

      :run_query ->
        execute_sql_query(app)

      :trigger_autocomplete ->
        SQLEditor.handle_key(%{app | focus: :editor}, {:ctrl, "space"})

      :clear_editor ->
        SQLEditor.handle_key(%{app | focus: :editor}, {:ctrl, "k"})

      :focus_grid ->
        set_focus(app, :datagrid)

      :switch_table_view ->
        switch_view(app, :table_view)

      :switch_query_view ->
        switch_view(app, :query_view)

      :cycle_inspector_format ->
        opened = if app.inspector_open, do: app, else: open_inspector(app)
        cycle_inspector_format(opened)

      :toggle_structure ->
        toggle_structure_view(app)

      :open_in_sql ->
        open_table_in_sql_editor(app)

      :filter_table ->
        open_filter_bar(app)

      :filter_by_cell ->
        filter_by_selected_cell(app)

      :clear_filter ->
        clear_table_filter(app)

      :toggle_inspector ->
        toggle_inspector(app)

      :export_data ->
        push_modal(app, ExportModal.new())

      :copy_cell ->
        handle_key(%{app | focus: :datagrid, datagrid_state: %{grid | mode: :selecting}}, "c")

      :copy_row ->
        handle_key(%{app | focus: :datagrid, datagrid_state: %{grid | mode: :selecting}}, "Y")

      :refresh ->
        refresh_active_table(app)

      :new_sql_tab ->
        request_new_sql_tab(app)

      :close_tab ->
        close_tab(app, app.active_tab_id)

      :next_tab ->
        cycle_tab(app, 1)

      :ai_settings ->
        open_ai_settings_modal(app)

      :check_updates ->
        open_update_modal(app)

      :ai_sql_assistant ->
        open_ai_sql_prompt(app)

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
    layout = Renderer.layout_for(app)
    areas = Renderer.datagrid_areas(layout.datagrid, app)
    dd = Renderer.filter_dropdown_data(app, layout.datagrid)

    cond do
      inside_area?(x, y, layout.footer) ->
        :pointer

      Map.has_key?(layout, :tabs) and inside_area?(x, y, layout.tabs) ->
        :pointer

      dd != nil and inside_area?(x, y, dd.rect) ->
        :pointer

      Map.get(layout, :ai_panel) != nil and inside_area?(x, y, layout.ai_panel) ->
        %{input_area: inp_area} =
          AIChatPanel.areas(layout.ai_panel, input_text: app.ai_input_text)

        if inp_area != nil and inside_area?(x, y, inp_area) do
          :text
        else
          :pointer
        end

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
    tab = active_tab(app)
    tab_id = tab && tab.id
    profile = resolve_tab_profile(app, tab)

    if profile do
      target_pid = self()
      offset = length(grid.rows)
      batch_size = grid.batch_size || 100
      schema = (tab && Map.get(tab, :schema)) || app.selected_schema

      Task.start(fn ->
        result =
          Sidebar.fetch_table_chunk(profile, table_name, offset, batch_size,
            schema: schema,
            order_by: grid.sort_by
          )

        send(target_pid, {:table_chunk_loaded, tab_id, table_name, offset, result})
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
  Triggers loading the next batch of rows for a paginated SQL query result in `:query_view`.
  """
  @spec load_more_query_data(t()) :: t()
  def load_more_query_data(
        %__MODULE__{
          active_view: :query_view,
          datagrid_state: %DataGrid{has_more: true, loading_more: false} = grid
        } = app
      ) do
    tab = active_tab(app)
    executed_sql = tab && Map.get(tab, :executed_sql)
    profile = resolve_tab_profile(app, tab)
    batch_size = grid.batch_size || 100
    offset = length(grid.rows)

    with true <- is_binary(executed_sql) and String.trim(executed_sql) != "",
         %Strata.ConnectionProfile{} <- profile,
         {:paginated, wrapped_sql, _limit} <-
           Strata.QueryBuilder.paginate_select_query(executed_sql, batch_size, offset) do
      target_pid = self()
      tab_id = tab.id
      req_id = Map.get(tab, :query_request_id)

      Task.start(fn ->
        chunk_res =
          case Strata.ConnectionWorker.execute_query_for_profile(profile, wrapped_sql) do
            {:ok, %{rows: rows}} ->
              has_more? = length(rows) > batch_size
              {:ok, %{rows: Enum.take(rows, batch_size), has_more: has_more?}}

            {:error, reason} ->
              {:error, reason}
          end

        send(target_pid, {:query_chunk_loaded, tab_id, req_id, offset, chunk_res})
      end)

      %{
        app
        | datagrid_state: %{grid | loading_more: true},
          status_message: "Loading more query rows..."
      }
    else
      _ -> app
    end
  end

  def load_more_query_data(app), do: app

  defp maybe_load_more(
         %__MODULE__{active_view: :table_view, datagrid_state: %DataGrid{}} = app,
         vh
       ) do
    if DataGrid.near_bottom?(app.datagrid_state, vh, 25),
      do: load_more_table_data(app),
      else: app
  end

  defp maybe_load_more(
         %__MODULE__{active_view: :query_view, datagrid_state: %DataGrid{}} = app,
         vh
       ) do
    if DataGrid.near_bottom?(app.datagrid_state, vh, 25),
      do: load_more_query_data(app),
      else: app
  end

  defp maybe_load_more(app, _vh), do: app

  @doc """
  Opens a new SQL Query tab and makes it active.
  """
  @spec open_tab(t(), keyword()) :: t()
  def open_tab(%__MODULE__{} = app, tab_opts \\ []) do
    app = persist_active_tab(app)
    tab_id = next_tab_id(app.tabs)
    name = Keyword.get(tab_opts, :name) || next_query_name(app.tabs)
    content = Keyword.get(tab_opts, :content, "")
    profile = Sidebar.resolve_profile_for_selection(app)

    new_tab =
      build_query_tab(tab_id, name,
        content: content,
        profile_id: Keyword.get(tab_opts, :profile_id, profile && profile.id),
        cursor: Keyword.get(tab_opts, :cursor, {0, 0}),
        ai_session_id: Keyword.get(tab_opts, :ai_session_id),
        ai_applied_msg_id: Keyword.get(tab_opts, :ai_applied_msg_id),
        ai_messages: Keyword.get(tab_opts, :ai_messages, [])
      )

    %{app | tabs: app.tabs ++ [new_tab]}
    |> hydrate_tab(new_tab)
    |> Map.put(:focus, :editor)
    |> save_workspace_async()
  end

  @doc """
  Closes tab with given ID and adjusts active tab, hydrating the newly focused tab.
  Prompts with `ConfirmModal` when the tab has uncommitted table edits unless `force: true`.
  """
  @spec close_tab(t(), String.t() | nil, keyword()) :: t()
  def close_tab(app, tab_id, opts \\ [])
  def close_tab(%__MODULE__{}, nil, _opts), do: %__MODULE__{}

  def close_tab(%__MODULE__{active_tab_id: active_id} = app, tab_id, opts) do
    app = persist_active_tab(app)
    closing_tab = Enum.find(app.tabs, &(&1.id == tab_id))
    force? = Keyword.get(opts, :force, false)
    {staged_count, inline_editing?} = dirty_state_for_tab(app, closing_tab)

    if not force? and closing_tab != nil and (staged_count > 0 or inline_editing?) do
      modal =
        ConfirmModal.new(
          kind: :close_dirty_tab,
          tab_id: closing_tab.id,
          tab_name: closing_tab.name,
          dirty_count: staged_count,
          inline_editing?: inline_editing?,
          can_commit?: true,
          focused_field: :cancel_button
        )

      push_modal(app, modal)
    else
      do_close_tab(app, active_id, tab_id, closing_tab)
    end
  end

  defp do_close_tab(app, active_id, tab_id, closing_tab) do
    closed_idx = Enum.find_index(app.tabs, &(&1.id == tab_id))
    remaining = Enum.reject(app.tabs, &(&1.id == tab_id))

    closed_entry =
      if closing_tab, do: Strata.WorkspaceStore.build_closed_tab_entry(closing_tab), else: nil

    updated_closed =
      Strata.WorkspaceStore.prepend_closed_tab(app.closed_tabs || [], closed_entry)

    app = %{app | closed_tabs: updated_closed}

    cond do
      is_nil(closed_idx) ->
        app

      active_id == tab_id ->
        case remaining do
          [] ->
            %{
              app
              | tabs: [],
                active_tab_id: nil,
                active_view: :table_view,
                selected_table: nil,
                selected_schema: nil,
                table_request_id: nil,
                datagrid_state: nil,
                structure_restore_grid: nil,
                active_filter: nil,
                filter_bar_open: false,
                filter_bar_focused: false,
                filter_bar_transient: false,
                filter_dropdown: nil,
                inspector_open: false,
                focus: :sidebar
            }
            |> save_workspace_sync()

          _ ->
            next_tab = Enum.at(remaining, min(closed_idx, length(remaining) - 1))

            %{app | tabs: remaining}
            |> hydrate_tab(next_tab)
            |> then(fn s ->
              cond do
                next_tab.kind == :table and s.focus == :editor -> %{s | focus: :datagrid}
                next_tab.kind == :query and s.focus == :datagrid -> %{s | focus: :editor}
                true -> s
              end
            end)
            |> save_workspace_sync()
        end

      true ->
        %{app | tabs: remaining}
        |> save_workspace_sync()
    end
  end

  defp handle_quit_request(state) do
    case dirty_tabs_info(state) do
      [] ->
        {:stop, state}

      [single] ->
        modal =
          ConfirmModal.new(
            kind: :quit_with_dirty_tabs,
            tab_id: single.tab.id,
            tab_name: single.tab.name,
            dirty_count: single.staged_count,
            inline_editing?: single.inline_editing?,
            can_commit?: true,
            focused_field: :cancel_button
          )

        {:noreply, push_modal(state, modal)}

      many ->
        modal =
          ConfirmModal.new(
            kind: :quit_with_dirty_tabs,
            tab_id: nil,
            tab_name: Enum.map_join(many, ", ", & &1.tab.name),
            dirty_count: Enum.sum(Enum.map(many, & &1.staged_count)),
            inline_editing?: Enum.any?(many, & &1.inline_editing?),
            can_commit?: false,
            focused_field: :cancel_button
          )

        {:noreply, push_modal(state, modal)}
    end
  end

  defp dirty_tabs_info(app) do
    persisted = persist_active_tab(app)

    Enum.flat_map(persisted.tabs, fn tab ->
      {staged_count, inline_editing?} = dirty_state_for_tab(persisted, tab)

      if staged_count > 0 or inline_editing? do
        [%{tab: tab, staged_count: staged_count, inline_editing?: inline_editing?}]
      else
        []
      end
    end)
  end

  defp dirty_grid?(%DataGrid{editing_cell: {_r, _c}}), do: true
  defp dirty_grid?(%DataGrid{} = grid), do: DataGrid.dirty_count(grid) > 0
  defp dirty_grid?(_), do: false

  defp dirty_state_for_tab(_app, nil), do: {0, false}

  defp dirty_state_for_tab(app, tab) do
    grid =
      if tab.id == app.active_tab_id do
        app.datagrid_state || Map.get(tab, :datagrid_state)
      else
        Map.get(tab, :datagrid_state)
      end

    staged_count = if match?(%DataGrid{}, grid), do: DataGrid.dirty_count(grid), else: 0

    inline_editing? =
      tab.id == app.active_tab_id and match?(%DataGrid{editing_cell: {_r, _c}}, grid)

    {staged_count, inline_editing?}
  end

  defp pop_confirm_modal_if_present(%{modals: [%ConfirmModal{} | _]} = state) do
    {_popped, popped_state} = pop_modal(state)
    popped_state
  end

  defp pop_confirm_modal_if_present(state), do: state

  defp commit_and_complete_confirm_modal(app, modal, rest) do
    target_tab_id = modal.tab_id || app.active_tab_id

    app =
      if target_tab_id && target_tab_id != app.active_tab_id do
        switch_tab(app, target_tab_id)
      else
        app
      end

    app =
      if match?(%DataGrid{editing_cell: {_r, _c}}, app.datagrid_state) do
        if app.inline_input_ref do
          handle_inline_edit_key(app, :enter)
        else
          %{app | datagrid_state: %{app.datagrid_state | editing_cell: nil}}
        end
      else
        app
      end

    dirty = if app.datagrid_state, do: DataGrid.dirty_count(app.datagrid_state), else: 0

    if dirty == 0 do
      {_popped, popped_app} = pop_modal(app)
      popped_app = %{popped_app | pending_commit_action: nil}

      case modal.kind do
        :quit_with_dirty_tabs ->
          %{popped_app | quit_requested?: true}

        :refresh_dirty_table ->
          load_table_async(popped_app, modal.tab_name || popped_app.selected_table, refresh: true)

        _ ->
          close_tab(popped_app, target_tab_id, force: true)
      end
    else
      committed_app = commit_staged_changes(app)

      if String.starts_with?(to_string(committed_app.status_message || ""), "❌") do
        err_modal = %{
          modal
          | status: :error,
            status_message: committed_app.status_message
        }

        %{committed_app | modals: [err_modal | rest], pending_commit_action: nil}
      else
        action =
          case modal.kind do
            :quit_with_dirty_tabs ->
              :quit

            :refresh_dirty_table ->
              {:refresh_tab, target_tab_id, modal.tab_name || app.selected_table}

            _ ->
              {:close_tab, target_tab_id}
          end

        saving_modal = %{
          modal
          | status: :saving,
            status_message: "⏳ Committing changes..."
        }

        %{committed_app | modals: [saving_modal | rest], pending_commit_action: action}
      end
    end
  end

  @doc """
  Switches active tab to the specified tab ID if present, saving and restoring per-tab state.
  """
  @spec switch_tab(t(), String.t()) :: t()
  def switch_tab(%__MODULE__{active_tab_id: tab_id} = app, tab_id), do: app

  def switch_tab(%__MODULE__{} = app, tab_id) do
    app = persist_active_tab(app)

    case Enum.find(app.tabs, &(&1.id == tab_id)) do
      nil ->
        app

      target ->
        app
        |> hydrate_tab(target)
        |> then(fn s ->
          cond do
            Map.get(target, :kind, :query) == :table and s.focus == :editor ->
              %{s | focus: :datagrid}

            Map.get(target, :kind, :query) == :query and s.focus == :datagrid ->
              %{s | focus: :editor}

            true ->
              s
          end
        end)
        |> save_workspace_async()
    end
  end

  @doc """
  Cycles across open tabs by `delta` (`+1` next, `-1` previous).
  """
  @spec cycle_tab(t(), integer()) :: t()
  def cycle_tab(%__MODULE__{tabs: []} = app, _delta), do: app

  def cycle_tab(%__MODULE__{tabs: tabs, active_tab_id: active_id} = app, delta) do
    idx = Enum.find_index(tabs, &(&1.id == active_id)) || 0
    cnt = length(tabs)
    target = Enum.at(tabs, rem(idx + delta + cnt, cnt))
    if target, do: switch_tab(app, target.id), else: app
  end

  @doc """
  Returns the currently active tab map, or `nil`.
  """
  @spec active_tab(t()) :: tab() | nil
  def active_tab(%__MODULE__{tabs: tabs, active_tab_id: active_id}) do
    Enum.find(tabs, &(&1.id == active_id))
  end

  defp active_tab_kind(%__MODULE__{} = app) do
    case active_tab(app) do
      %{kind: kind} -> kind
      nil -> if app.active_view == :query_view, do: :query, else: :table
    end
  end

  @doc """
  Asynchronously executes active SQL tab content so the TUI render loop never blocks.
  """
  @spec execute_sql_query_async(t()) :: t()
  def execute_sql_query_async(%__MODULE__{} = app) do
    app = persist_active_tab(app)
    tab = active_tab(app)
    sql = if tab, do: String.trim(Map.get(tab, :content, "")), else: ""

    if sql == "" do
      %{app | status_message: "⚠️ Cannot execute empty SQL query"}
    else
      profile = resolve_tab_profile(app, tab)

      if profile do
        caller = self()
        tab_id = tab.id
        req_id = System.unique_integer([:positive])
        ddl? = Regex.match?(~r/^\s*(CREATE|DROP|ALTER|TRUNCATE)\b/i, sql)

        app =
          update_tab_by_id(app, tab_id, fn t ->
            Map.merge(t, %{executed_sql: sql, query_request_id: req_id})
          end)

        Task.start(fn ->
          start_time = System.monotonic_time(:millisecond)
          res = execute_paginated_query(profile, sql, 100)
          elapsed = max(1, System.monotonic_time(:millisecond) - start_time)
          send(caller, {:sql_query_finished, tab_id, elapsed, profile, ddl?, res})
        end)

        %{app | status_message: "⏳ Executing SQL query..."}
      else
        %{app | status_message: "❌ No active database connection configured"}
      end
    end
  end

  @doc """
  Executes active SQL tab content synchronously against connected DB profile.
  Preserves raw cell values for `Strata.Formatter` and the Right Inspector.
  """
  @spec execute_sql_query(t()) :: t()
  def execute_sql_query(%__MODULE__{} = app) do
    app = persist_active_tab(app)
    tab = active_tab(app)
    sql = if tab, do: String.trim(Map.get(tab, :content, "")), else: ""

    if sql == "" do
      %{app | status_message: "⚠️ Cannot execute empty SQL query"}
    else
      profile = resolve_tab_profile(app, tab)

      if profile do
        req_id = System.unique_integer([:positive])

        app =
          update_tab_by_id(app, tab.id, fn t ->
            Map.merge(t, %{executed_sql: sql, query_request_id: req_id})
          end)

        start_time = System.monotonic_time(:millisecond)
        res = execute_paginated_query(profile, sql, 100)
        elapsed = max(1, System.monotonic_time(:millisecond) - start_time)
        apply_sql_query_result(app, tab.id, elapsed, res)
      else
        %{app | status_message: "❌ No active database connection configured"}
      end
    end
  end

  defp execute_paginated_query(profile, sql, batch_size) do
    case Strata.QueryBuilder.paginate_select_query(sql, batch_size, 0) do
      {:paginated, wrapped_sql, limit} ->
        case Strata.ConnectionWorker.execute_query_for_profile(profile, wrapped_sql) do
          {:ok, %{columns: cols, rows: rows}} ->
            has_more? = length(rows) > limit
            {:ok, %{columns: cols, rows: Enum.take(rows, limit), has_more: has_more?}}

          {:error, _wrapped_err} ->
            # Fallback to running the raw statement cleanly if derived-table wrapping fails (e.g., duplicate columns in MySQL)
            Strata.ConnectionWorker.execute_query_for_profile(profile, sql)
        end

      :passthrough ->
        Strata.ConnectionWorker.execute_query_for_profile(profile, sql)
    end
  end

  defp build_table_tab(id, name, opts) do
    %{
      id: id,
      kind: :table,
      name: name,
      table_name: Keyword.get(opts, :table_name, name),
      schema: Keyword.get(opts, :schema),
      profile_id: Keyword.get(opts, :profile_id),
      table_request_id: Keyword.get(opts, :table_request_id),
      datagrid_state: Keyword.get(opts, :datagrid_state),
      structure_restore_grid: Keyword.get(opts, :structure_restore_grid),
      active_filter: Keyword.get(opts, :active_filter),
      filter_bar_open: Keyword.get(opts, :filter_bar_open, false),
      filter_bar_focused: Keyword.get(opts, :filter_bar_focused, false),
      filter_bar_transient: Keyword.get(opts, :filter_bar_transient, false),
      filter_bar_focus_part: Keyword.get(opts, :filter_bar_focus_part, :value),
      filter_bar_col: Keyword.get(opts, :filter_bar_col, "* All"),
      filter_bar_op: Keyword.get(opts, :filter_bar_op, :contains),
      filter_bar_text: Keyword.get(opts, :filter_bar_text, ""),
      filter_dropdown: nil,
      filter_dropdown_idx: 0,
      filter_dropdown_search: "",
      inspector_open: Keyword.get(opts, :inspector_open, false),
      inspector_value_scroll: Keyword.get(opts, :inspector_value_scroll, 0),
      inspector_summary_scroll: Keyword.get(opts, :inspector_summary_scroll, 0),
      inspector_format: Keyword.get(opts, :inspector_format, :auto)
    }
  end

  defp build_query_tab(id, name, opts) do
    %{
      id: id,
      kind: :query,
      name: name,
      profile_id: Keyword.get(opts, :profile_id),
      content: Keyword.get(opts, :content, ""),
      cursor: Keyword.get(opts, :cursor, {0, 0}),
      scroll_offset: Keyword.get(opts, :scroll_offset, nil),
      diagnostics: Keyword.get(opts, :diagnostics, []),
      executed_sql: Keyword.get(opts, :executed_sql),
      query_request_id: Keyword.get(opts, :query_request_id),
      ai_session_id: Keyword.get(opts, :ai_session_id),
      ai_applied_msg_id: Keyword.get(opts, :ai_applied_msg_id),
      ai_messages: Keyword.get(opts, :ai_messages, []),
      last_query_error: Keyword.get(opts, :last_query_error),
      completion:
        Keyword.get(opts, :completion, %{
          active?: false,
          suggestions: [],
          selected_index: 0,
          prefix: ""
        }),
      datagrid_state: Keyword.get(opts, :datagrid_state),
      inspector_open: Keyword.get(opts, :inspector_open, false),
      inspector_value_scroll: Keyword.get(opts, :inspector_value_scroll, 0),
      inspector_summary_scroll: Keyword.get(opts, :inspector_summary_scroll, 0),
      inspector_format: Keyword.get(opts, :inspector_format, :auto)
    }
  end

  defp next_tab_id(tabs) do
    max_num =
      tabs
      |> Enum.map(fn t ->
        case Regex.run(~r/^tab_(\d+)$/, to_string(t.id)) do
          [_, n] -> String.to_integer(n)
          _ -> 0
        end
      end)
      |> Enum.max(fn -> 0 end)

    "tab_#{max_num + 1}"
  end

  defp next_query_name(tabs) do
    q_count =
      tabs
      |> Enum.count(&(Map.get(&1, :kind, :query) == :query))

    "Query #{q_count + 1}"
  end

  defp find_table_tab(tabs, profile_id, schema, table_name) do
    Enum.find(tabs, fn t ->
      Map.get(t, :kind) == :table and
        Map.get(t, :table_name) == table_name and
        Map.get(t, :schema) == schema and
        (Map.get(t, :profile_id) == profile_id or is_nil(Map.get(t, :profile_id)) or
           is_nil(profile_id))
    end)
  end

  defp find_tab_by_request(tabs, req_id, table_name) do
    Enum.find(tabs, fn t ->
      Map.get(t, :kind) == :table and
        Map.get(t, :table_request_id) == req_id and
        Map.get(t, :table_name) == table_name
    end)
  end

  defp persist_active_tab(%__MODULE__{active_tab_id: nil} = app), do: app

  defp persist_active_tab(%__MODULE__{tabs: tabs, active_tab_id: active_id} = app) do
    updated_tabs =
      Enum.map(tabs, fn tab ->
        if tab.id == active_id do
          kind = Map.get(tab, :kind, :query)

          base =
            Map.merge(tab, %{
              datagrid_state: app.datagrid_state,
              inspector_open: app.inspector_open,
              inspector_value_scroll: app.inspector_value_scroll,
              inspector_summary_scroll: app.inspector_summary_scroll,
              inspector_format: app.inspector_format
            })

          if kind == :table do
            Map.merge(base, %{
              table_name: app.selected_table || Map.get(tab, :table_name),
              schema: app.selected_schema || Map.get(tab, :schema),
              table_request_id: app.table_request_id,
              structure_restore_grid: app.structure_restore_grid,
              active_filter: app.active_filter,
              filter_bar_open: app.filter_bar_open,
              filter_bar_focused: app.filter_bar_focused,
              filter_bar_transient: app.filter_bar_transient,
              filter_bar_focus_part: app.filter_bar_focus_part,
              filter_bar_col: app.filter_bar_col,
              filter_bar_op: app.filter_bar_op,
              filter_bar_text: app.filter_bar_text,
              filter_dropdown: app.filter_dropdown,
              filter_dropdown_idx: app.filter_dropdown_idx,
              filter_dropdown_search: app.filter_dropdown_search
            })
          else
            base
          end
        else
          tab
        end
      end)

    %{app | tabs: updated_tabs}
  end

  defp hydrate_tab(app, tab) do
    kind = Map.get(tab, :kind, :query)
    view = if kind == :table, do: :table_view, else: :query_view

    base = %{
      app
      | active_tab_id: tab.id,
        active_view: view,
        datagrid_state: Map.get(tab, :datagrid_state),
        inspector_open: Map.get(tab, :inspector_open, false),
        inspector_value_scroll: Map.get(tab, :inspector_value_scroll, 0),
        inspector_summary_scroll: Map.get(tab, :inspector_summary_scroll, 0),
        inspector_format: Map.get(tab, :inspector_format, :auto),
        inline_input_ref: nil,
        drag_anchor: nil,
        text_selection: nil,
        selection_screen: nil,
        selection_bounds: nil
    }

    if kind == :table do
      f_text = Map.get(tab, :filter_bar_text, "")
      if base.filter_bar_ref, do: ExRatatui.text_input_set_value(base.filter_bar_ref, f_text)
      next_focus = if base.focus == :ai_panel, do: :datagrid, else: base.focus

      %{
        base
        | focus: next_focus,
          selected_table: Map.get(tab, :table_name),
          selected_schema: Map.get(tab, :schema),
          table_request_id: Map.get(tab, :table_request_id),
          structure_restore_grid: Map.get(tab, :structure_restore_grid),
          active_filter: Map.get(tab, :active_filter),
          filter_bar_open: Map.get(tab, :filter_bar_open, false),
          filter_bar_focused: Map.get(tab, :filter_bar_focused, false),
          filter_bar_transient: Map.get(tab, :filter_bar_transient, false),
          filter_bar_focus_part: Map.get(tab, :filter_bar_focus_part, :value),
          filter_bar_col: Map.get(tab, :filter_bar_col, "* All"),
          filter_bar_op: Map.get(tab, :filter_bar_op, :contains),
          filter_bar_text: f_text,
          filter_dropdown: Map.get(tab, :filter_dropdown),
          filter_dropdown_idx: Map.get(tab, :filter_dropdown_idx, 0),
          filter_dropdown_search: Map.get(tab, :filter_dropdown_search, "")
      }
    else
      msgs = Map.get(tab, :ai_messages, [])

      %{
        base
        | selected_table: nil,
          selected_schema: nil,
          table_request_id: nil,
          structure_restore_grid: nil,
          active_filter: nil,
          filter_bar_open: false,
          filter_bar_focused: false,
          filter_bar_transient: false,
          filter_bar_focus_part: :value,
          filter_bar_col: "* All",
          filter_bar_op: :contains,
          filter_bar_text: "",
          filter_dropdown: nil,
          filter_dropdown_idx: 0,
          filter_dropdown_search: "",
          ai_selected_msg_idx: if(msgs == [], do: nil, else: length(msgs) - 1)
      }
      |> sync_ai_panel_scroll_to_bottom()
    end
  end

  defp update_tab_by_id(app, tab_id, fun) do
    app = persist_active_tab(app)

    case Enum.find(app.tabs, &(&1.id == tab_id)) do
      nil ->
        app

      tab ->
        updated_tab = fun.(tab)
        updated_tabs = Enum.map(app.tabs, fn t -> if t.id == tab_id, do: updated_tab, else: t end)
        app = %{app | tabs: updated_tabs}

        if app.active_tab_id == tab_id do
          hydrate_tab(app, updated_tab)
        else
          app
        end
    end
  end

  defp resolve_profile_by_id(nil), do: nil

  defp resolve_profile_by_id(profile_id) do
    Strata.ConfigStore.get_profile(profile_id)
  catch
    _, _ -> nil
  end

  defp resolve_tab_profile(app, nil), do: Sidebar.resolve_profile_for_selection(app)

  defp resolve_tab_profile(app, tab) do
    resolve_profile_by_id(Map.get(tab, :profile_id)) || Sidebar.resolve_profile_for_selection(app)
  end

  @doc """
  Pushes a modal overlay map to the top of the modals stack.
  """
  @spec push_modal(t(), map()) :: t()
  def push_modal(%__MODULE__{modals: modals} = app, modal) when is_map(modal) do
    %{app | modals: [modal | modals], modal_dropdown: nil}
  end

  @doc """
  Pops top modal from stack, returning {popped_modal, updated_app}.
  """
  @spec pop_modal(t()) :: {map() | nil, t()}
  def pop_modal(%__MODULE__{modals: [top | rest]} = app) do
    {top, %{app | modals: rest, modal_dropdown: nil}}
  end

  def pop_modal(%__MODULE__{modals: []} = app) do
    {nil, %{app | modal_dropdown: nil}}
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

  def handle_key(%__MODULE__{} = app, {:ctrl, "v"}) do
    case Strata.Clipboard.paste() do
      {:ok, ""} -> %{app | status_message: "📋 Clipboard is empty"}
      {:ok, text} -> paste_text(app, text)
      {:error, _} -> %{app | status_message: "📋 Paste failed (no OS clipboard tool)"}
    end
  end

  def handle_key(%__MODULE__{modals: [top | rest], modal_dropdown: %{} = dd} = app, key) do
    handle_modal_dropdown_key(app, top, rest, dd, key)
  end

  def handle_key(%__MODULE__{modals: [top | rest]} = app, key) do
    if key in [:enter, :space] and select_field_focused?(app, top) do
      open_modal_dropdown(app, top, top.focused_field)
    else
      handle_modal_key_dispatch(app, top, rest, key)
    end
  end

  def handle_key(%__MODULE__{} = app, {:ctrl, "enter"}), do: run_or_refresh_active(app)
  def handle_key(%__MODULE__{} = app, {:ctrl, "r"}), do: run_or_refresh_active(app)
  def handle_key(%__MODULE__{} = app, {:ctrl, "t"}), do: request_new_sql_tab(app)
  def handle_key(%__MODULE__{} = app, {:ctrl, "p"}), do: open_actions_modal(app)

  def handle_key(%__MODULE__{active_view: :table_view} = app, {:ctrl, "g"}),
    do: open_table_in_sql_editor(app)

  def handle_key(%__MODULE__{} = app, key) when key in [{:ctrl, "o"}, :f6] do
    open_ai_sql_prompt(app)
  end

  def handle_key(%__MODULE__{} = app, {:ctrl, "w"}), do: close_tab(app, app.active_tab_id)
  def handle_key(%__MODULE__{} = app, {:ctrl, :left}), do: cycle_tab(app, -1)
  def handle_key(%__MODULE__{} = app, {:ctrl, :right}), do: cycle_tab(app, 1)

  def handle_key(%__MODULE__{focus: :editor} = app, :tab) do
    active = active_tab(app)
    comp = Map.get(active || %{}, :completion, %{})

    if Map.get(comp, :active?, false) and Map.get(comp, :suggestions, []) != [] do
      SQLEditor.handle_key(app, :tab)
    else
      cycle_focus(app, :next)
    end
  end

  def handle_key(%__MODULE__{} = app, :tab), do: cycle_focus(app, :next)
  def handle_key(%__MODULE__{} = app, :shift_tab), do: cycle_focus(app, :prev)
  def handle_key(%__MODULE__{} = app, :f1), do: switch_view(app, :table_view)
  def handle_key(%__MODULE__{} = app, :f2), do: switch_view(app, :query_view)
  def handle_key(%__MODULE__{} = app, :f3), do: toggle_structure_view(app)
  def handle_key(%__MODULE__{} = app, :f4), do: toggle_inspector(app)

  def handle_key(%__MODULE__{focus: focus} = app, "?")
      when focus not in [:editor, :ai_panel] do
    open_actions_modal(app)
  end

  def handle_key(%__MODULE__{} = app, {:ctrl, "1"}), do: switch_view(app, :table_view)
  def handle_key(%__MODULE__{} = app, {:ctrl, "2"}), do: switch_view(app, :query_view)
  def handle_key(%__MODULE__{} = app, {:ctrl, "3"}), do: set_focus(app, :datagrid)

  def handle_key(%__MODULE__{focus: focus} = app, "1")
      when focus not in [:editor, :ai_panel],
      do: switch_view(app, :table_view)

  def handle_key(%__MODULE__{focus: focus} = app, "2")
      when focus not in [:editor, :ai_panel],
      do: switch_view(app, :query_view)

  def handle_key(%__MODULE__{focus: focus} = app, "3")
      when focus not in [:editor, :ai_panel],
      do: set_focus(app, :datagrid)

  def handle_key(%__MODULE__{focus: :sidebar} = app, key) do
    Sidebar.handle_key(app, key)
  end

  def handle_key(%__MODULE__{focus: :ai_panel} = app, key) do
    handle_ai_panel_key(app, key)
  end

  def handle_key(%__MODULE__{focus: :editor} = app, key) do
    case key do
      :esc ->
        active = active_tab(app)
        comp = Map.get(active || %{}, :completion, %{})

        if Map.get(comp, :active?, false) and Map.get(comp, :suggestions, []) != [] do
          SQLEditor.handle_key(app, :esc)
        else
          set_focus(app, :datagrid)
        end

      _ ->
        mapped = if key == :shift_enter, do: :enter, else: key
        updated = SQLEditor.handle_key(app, mapped)
        if editor_mutating_key?(mapped), do: save_workspace_async(updated), else: updated
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

    if app.active_view in [:table_view, :query_view] and
         key in [:down, :page_down, :end, "j", "J"] do
      maybe_load_more(app, vh)
    else
      app
    end
  end

  def handle_key(%__MODULE__{} = app, _key), do: app

  defp handle_modal_key_dispatch(app, top, rest, key) do
    case key do
      :esc when not is_struct(top, SQLTabPickerModal) ->
        {_popped, app} = pop_modal(app)
        if is_struct(top, ConfirmModal), do: %{app | pending_commit_action: nil}, else: app

      _ ->
        cond do
          match?(%SQLTabPickerModal{}, top) ->
            case SQLTabPickerModal.handle_key(top, key) do
              {:new_blank, _modal} ->
                {_popped, app} = pop_modal(app)
                open_tab(app)

              {:reopen, closed_tab, _modal} ->
                {_popped, app} = pop_modal(app)
                reopen_closed_tab(app, closed_tab)

              {:delete_closed, closed_id, updated_modal} ->
                remaining_closed =
                  Enum.reject(app.closed_tabs || [], &(Map.get(&1, :id) == closed_id))

                %{app | closed_tabs: remaining_closed, modals: [updated_modal | rest]}
                |> save_workspace_async()

              {:cancel, _modal} ->
                {_popped, app} = pop_modal(app)
                app

              %SQLTabPickerModal{} = updated_modal ->
                %{app | modals: [updated_modal | rest]}
            end

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

          match?(%ConnectionModal{}, top) ->
            case ConnectionModal.handle_key(top, key) do
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

          match?(%AISettingsModal{}, top) ->
            case AISettingsModal.handle_key(top, key) do
              {:save, modal} ->
                settings = AISettingsModal.to_settings(modal)

                try do
                  Strata.AISettingsStore.put(settings)
                catch
                  _, _ -> :ok
                end

                {_popped, app} = pop_modal(app)

                %{
                  app
                  | status_message:
                      "Saved AI settings (#{Strata.AISettings.cli_command(settings.provider)})"
                }

              {:test, _modal} ->
                test_ai_cli_async(app)

              {:cancel, _modal} ->
                {_popped, app} = pop_modal(app)
                app

              %AISettingsModal{} = updated_modal ->
                %{app | modals: [updated_modal | rest]}
            end

          match?(%UpdateModal{}, top) ->
            case UpdateModal.handle_key(top, key) do
              {:check, _modal} ->
                check_updates_async(app)

              {:install, _modal} ->
                install_update_async(app)

              {:cancel, _modal} ->
                {_popped, app} = pop_modal(app)
                app

              %UpdateModal{} = updated_modal ->
                %{app | modals: [updated_modal | rest]}
            end

          match?(%ConfirmModal{}, top) ->
            case ConfirmModal.handle_key(top, key) do
              {:discard, modal} ->
                {_popped, app} = pop_modal(app)
                app = %{app | pending_commit_action: nil}

                case modal.kind do
                  :quit_with_dirty_tabs ->
                    %{app | quit_requested?: true}

                  :refresh_dirty_table ->
                    app =
                      if modal.tab_id && modal.tab_id != app.active_tab_id,
                        do: switch_tab(app, modal.tab_id),
                        else: app

                    app = cancel_inline_edit_if_active(app)
                    load_table_async(app, modal.tab_name || app.selected_table, refresh: true)

                  _ ->
                    app =
                      if modal.tab_id == app.active_tab_id,
                        do: cancel_inline_edit_if_active(app),
                        else: app

                    close_tab(app, modal.tab_id, force: true)
                end

              {:commit, modal} ->
                commit_and_complete_confirm_modal(app, modal, rest)

              {:cancel, _modal} ->
                {_popped, app} = pop_modal(app)
                %{app | pending_commit_action: nil}

              %ConfirmModal{} = updated_modal ->
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

          match?(%ExportModal{}, top) ->
            case ExportModal.handle_key(top, key) do
              {:apply, {:export, format, file_path, scope}, modal} ->
                {_popped, app} = pop_modal(app)
                export_grid_data(app, modal, format, file_path, scope)

              {:cancel, _modal} ->
                {_popped, app} = pop_modal(app)
                app

              %ExportModal{} = updated_modal ->
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

  defp select_field_focused?(%__MODULE__{window_size: ws} = _app, top) when is_struct(top) do
    focused = Map.get(top, :focused_field)

    if is_atom(focused) do
      modal_area = Renderer.modal_area_for(%{modals: [top]}, ws)

      modal_area
      |> then(&Renderer.modal_rendered_info(top, &1))
      |> Map.get(:fields, [])
      |> Enum.any?(fn f -> f.key == focused and Map.get(f, :type) == :select end)
    else
      false
    end
  end

  defp select_field_focused?(_app, _top), do: false

  defp open_modal_dropdown(app, top, field) do
    opts = Renderer.modal_dropdown_options(top, field)

    if opts == [] do
      app
    else
      sel_idx = Enum.find_index(opts, & &1.selected?) || 0
      %{app | modal_dropdown: %{field: field, index: sel_idx, search: ""}}
    end
  end

  defp apply_modal_dropdown_choice(app, top, rest, field, value) when is_struct(top) do
    mod = top.__struct__

    updated_top =
      if Code.ensure_loaded?(mod) and function_exported?(mod, :apply_dropdown_selection, 3) do
        mod.apply_dropdown_selection(top, field, value)
      else
        top
      end

    %{app | modals: [updated_top | rest], modal_dropdown: nil}
  end

  defp handle_modal_dropdown_key(app, top, rest, dd, key) do
    dd_data = Renderer.modal_dropdown_data(app, app.window_size)
    items = (dd_data && dd_data.items) || []
    count = length(items)
    cur_idx = if dd_data, do: dd_data.selected_index, else: 0

    case key do
      :esc ->
        %{app | modal_dropdown: nil}

      k when k == :enter or (k == :space and dd.search == "") ->
        case Enum.at(items, cur_idx) do
          %{value: val} -> apply_modal_dropdown_choice(app, top, rest, dd.field, val)
          nil -> %{app | modal_dropdown: nil}
        end

      :space ->
        %{app | modal_dropdown: %{dd | search: dd.search <> " ", index: 0}}

      k when k in [:down, :tab] ->
        next_idx = if count > 0, do: rem(cur_idx + 1, count), else: 0
        %{app | modal_dropdown: %{dd | index: next_idx}}

      k when k in [:up, :shift_tab] ->
        prev_idx = if count > 0, do: rem(cur_idx - 1 + count, count), else: 0
        %{app | modal_dropdown: %{dd | index: prev_idx}}

      :backspace ->
        len = String.length(dd.search)

        %{
          app
          | modal_dropdown: %{dd | search: String.slice(dd.search, 0, max(0, len - 1)), index: 0}
        }

      k when is_binary(k) ->
        if String.printable?(k) do
          %{app | modal_dropdown: %{dd | search: dd.search <> k, index: 0}}
        else
          app
        end

      _ ->
        app
    end
  end

  defp editor_mutating_key?(key) when is_binary(key), do: true

  defp editor_mutating_key?(key)
       when key in [:enter, :backspace, :delete, :tab, {:ctrl, "k"}, {:ctrl, "u"}],
       do: true

  defp editor_mutating_key?(_), do: false

  defp handle_ai_panel_key(app, :esc) do
    cond do
      app.ai_request != nil ->
        cancel_ai_request(app)

      app.ai_panel_focus == :history ->
        %{app | ai_panel_focus: :input}

      true ->
        %{app | focus: :editor}
    end
  end

  defp handle_ai_panel_key(%__MODULE__{ai_panel_focus: :history} = app, key) do
    tab = active_tab(app)
    messages = (tab && Map.get(tab, :ai_messages, [])) || []

    if messages == [] do
      %{app | ai_panel_focus: :input}
    else
      max_idx = length(messages) - 1
      curr_idx = max(0, min(max_idx, app.ai_selected_msg_idx || max_idx))

      case key do
        k when k in [:up, "k", "K"] ->
          next_idx = max(0, curr_idx - 1)
          scroll_to_ai_turn(%{app | ai_selected_msg_idx: next_idx}, next_idx)

        k when k in [:down, "j", "J"] ->
          if curr_idx >= max_idx do
            %{app | ai_panel_focus: :input}
          else
            next_idx = curr_idx + 1
            scroll_to_ai_turn(%{app | ai_selected_msg_idx: next_idx}, next_idx)
          end

        :home ->
          scroll_to_ai_turn(%{app | ai_selected_msg_idx: 0}, 0)

        :end ->
          scroll_to_ai_turn(%{app | ai_selected_msg_idx: max_idx}, max_idx)

        k when k in [:enter, :space] ->
          apply_ai_history_turn(app, curr_idx)

        {:ctrl, "l"} ->
          reset_ai_tab_conversation(app)

        _ ->
          app
      end
    end
  end

  defp handle_ai_panel_key(%__MODULE__{ai_panel_focus: :input} = app, key) do
    case key do
      :enter ->
        if app.ai_request != nil, do: app, else: submit_ai_chat_input(app)

      k when k in [:shift_enter, :alt_enter, "\n", {:ctrl, "j"}] ->
        insert_ai_input_text(app, "\n")

      :up ->
        tab = active_tab(app)
        messages = (tab && Map.get(tab, :ai_messages, [])) || []

        if messages != [] do
          last_idx = length(messages) - 1

          scroll_to_ai_turn(
            %{app | ai_panel_focus: :history, ai_selected_msg_idx: last_idx},
            last_idx
          )
        else
          app
        end

      :left ->
        pos = clamp_ai_cursor(app.ai_input_cursor, app.ai_input_text)
        new_pos = AIChatPanel.move_cursor_left(app.ai_input_text || "", pos, app.ai_pastes || %{})
        %{app | ai_input_cursor: new_pos}

      :right ->
        pos = clamp_ai_cursor(app.ai_input_cursor, app.ai_input_text)

        new_pos =
          AIChatPanel.move_cursor_right(app.ai_input_text || "", pos, app.ai_pastes || %{})

        %{app | ai_input_cursor: new_pos}

      :home ->
        %{app | ai_input_cursor: 0}

      :end ->
        %{app | ai_input_cursor: String.length(app.ai_input_text || "")}

      k when k in [{:ctrl, "u"}, {:ctrl, "k"}] ->
        %{app | ai_input_text: "", ai_input_cursor: 0, ai_pastes: %{}, ai_paste_seq: 0}

      {:ctrl, "f"} ->
        trigger_ai_fix_error(app)

      {:ctrl, "l"} ->
        reset_ai_tab_conversation(app)

      :backspace ->
        val = app.ai_input_text || ""
        pos = clamp_ai_cursor(app.ai_input_cursor, val)

        {new_val, new_pos, new_pastes} =
          AIChatPanel.delete_before_cursor(val, pos, app.ai_pastes || %{})

        %{app | ai_input_text: new_val, ai_input_cursor: new_pos, ai_pastes: new_pastes}

      :delete ->
        val = app.ai_input_text || ""
        pos = clamp_ai_cursor(app.ai_input_cursor, val)

        {new_val, new_pos, new_pastes} =
          AIChatPanel.delete_at_cursor(val, pos, app.ai_pastes || %{})

        %{app | ai_input_text: new_val, ai_input_cursor: new_pos, ai_pastes: new_pastes}

      ch when is_binary(ch) ->
        if String.printable?(ch), do: insert_ai_input_text(app, ch), else: app

      _ ->
        app
    end
  end

  defp insert_ai_input_text(app, text) when is_binary(text) do
    val = app.ai_input_text || ""
    pos = clamp_ai_cursor(app.ai_input_cursor, val)
    new_val = String.slice(val, 0, pos) <> text <> String.slice(val, pos..-1//1)
    %{app | ai_input_text: new_val, ai_input_cursor: pos + String.length(text)}
  end

  defp clamp_ai_cursor(pos, str) do
    len = String.length(to_string(str || ""))
    max(0, min(pos || len, len))
  end

  defp trigger_ai_fix_error(app) do
    tab = active_tab(app)
    err = tab && Map.get(tab, :last_query_error)

    if is_binary(err) and String.trim(err) != "" and app.ai_request == nil do
      prompt = "Fix the SQL error in the current query: #{String.slice(String.trim(err), 0, 220)}"
      start_ai_sql_task(app, prompt)
    else
      app
    end
  end

  defp scroll_to_ai_turn(app, idx) do
    areas = Renderer.layout_for(app)

    case Map.get(areas, :ai_panel) do
      %{} = ai_area ->
        %{history_area: hist_area} = AIChatPanel.areas(ai_area)
        tab = active_tab(app)
        data = AIChatPanel.history_data(app, tab, hist_area)

        new_scroll =
          AIChatPanel.scroll_for_selected_turn(
            data.turn_ranges,
            idx,
            data.scroll_top,
            data.viewport_h
          )

        %{app | ai_history_scroll: new_scroll}

      nil ->
        app
    end
  end

  defp export_grid_data(app, modal, format, file_path, scope) do
    grid = app.datagrid_state || DataGrid.new()

    rows =
      case scope do
        :visible ->
          layout = Renderer.layout(app.window_size, app.active_view)
          %{grid_area: grid_area} = Renderer.datagrid_areas(layout.datagrid, app)
          vh = max(1, grid_area.height - 3)
          DataGrid.visible_rows(grid, vh)

        _ ->
          grid.rows
      end

    formatted =
      ExportModal.format_export(modal, grid.columns, rows,
        table_name: app.selected_table || "export_table"
      )

    case File.write(file_path, formatted) do
      :ok ->
        %{
          app
          | status_message: "📤 Exported #{length(rows)} rows (#{format}) to #{file_path}"
        }

      {:error, reason} ->
        %{app | status_message: "❌ Export failed: #{Strata.Formatter.format_error(reason)}"}
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

  def handle_mouse(
        %__MODULE__{modals: [%SQLTabPickerModal{} = picker | rest]} = app,
        {:scroll, dir, _x, _y}
      ) do
    items = SQLTabPickerModal.visible_items(picker)
    max_idx = max(0, length(items) - 1)

    next =
      if dir in [:up, :scroll_up] do
        max(0, picker.selected_index - 1)
      else
        min(max_idx, picker.selected_index + 1)
      end

    %{app | modals: [%{picker | selected_index: next} | rest]}
  end

  def handle_mouse(
        %__MODULE__{modals: [_ | _], modal_dropdown: %{} = dd, window_size: ws} = app,
        {:scroll, dir, _x, _y}
      ) do
    dd_data = Renderer.modal_dropdown_data(app, ws)
    items = (dd_data && dd_data.items) || []
    count = length(items)

    cond do
      count == 0 ->
        app

      dir in [:up, :scroll_up] ->
        %{app | modal_dropdown: %{dd | index: max(0, dd.index - 1)}}

      dir in [:down, :scroll_down] ->
        %{app | modal_dropdown: %{dd | index: min(count - 1, dd.index + 1)}}

      true ->
        app
    end
  end

  def handle_mouse(
        %__MODULE__{modals: [top | rest], modal_dropdown: %{} = dd, window_size: ws} = app,
        {:click, x, y}
      ) do
    case Renderer.modal_dropdown_data(app, ws) do
      %{rect: dd_rect, items: items, scroll_top: scroll_top} when is_map(dd_rect) ->
        if inside_area?(x, y, dd_rect) do
          rel_y = y - dd_rect.y - 1

          if rel_y >= 0 do
            case Enum.at(items, scroll_top + rel_y) do
              %{value: val} -> apply_modal_dropdown_choice(app, top, rest, dd.field, val)
              nil -> app
            end
          else
            app
          end
        else
          %{app | modal_dropdown: nil}
        end

      _ ->
        %{app | modal_dropdown: nil}
    end
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
      {popped, updated} = pop_modal(app)

      if is_struct(popped, ConfirmModal),
        do: %{updated | pending_commit_action: nil},
        else: updated
    end
  end

  def handle_mouse(
        %__MODULE__{filter_dropdown: kind, window_size: ws, active_view: active_view} = app,
        {:scroll, dir, _x, _y}
      )
      when kind in [:column, :op, :sort] do
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
        %__MODULE__{active_view: active_view} = app,
        {:scroll, dir, x, y}
      ) do
    layout = Renderer.layout_for(app)

    cond do
      Map.get(layout, :ai_panel) != nil and inside_area?(x, y, layout.ai_panel) ->
        if dir in [:up, :scroll_up, :down, :scroll_down] do
          {allow?, new_lock} = evaluate_scroll_lock(app.scroll_lock, :vertical)
          app = %{app | scroll_lock: new_lock}

          if allow? do
            delta = if dir in [:up, :scroll_up], do: -3, else: 3
            scroll_ai_history(app, layout.ai_panel, delta)
          else
            app
          end
        else
          app
        end

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

      layout.editor.height > 0 and inside_area?(x, y, layout.editor) ->
        if dir in [:up, :scroll_up, :down, :scroll_down] do
          {allow?, new_lock} = evaluate_scroll_lock(app.scroll_lock, :vertical)
          app = %{app | scroll_lock: new_lock}

          if allow? do
            delta = if dir in [:up, :scroll_up], do: -3, else: 3
            SQLEditor.scroll_viewport(app, layout.editor, delta)
          else
            app
          end
        else
          app
        end

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

            if active_view in [:table_view, :query_view] and raw_direction == :down do
              maybe_load_more(app, vh)
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

  def handle_mouse(%__MODULE__{} = app, {:click, x, y}) do
    layout = Renderer.layout_for(app)

    cond do
      inside_area?(x, y, layout.footer) ->
        handle_footer_click(app, x, y, layout.footer)

      Map.get(layout, :ai_panel) != nil and inside_area?(x, y, layout.ai_panel) ->
        handle_ai_panel_click(app, x, y, layout.ai_panel)

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

      Map.has_key?(layout, :tabs) and layout.tabs.height > 0 and inside_area?(x, y, layout.tabs) ->
        handle_tab_bar_click(app, x, y, layout.tabs)

      layout.editor.height > 0 and inside_area?(x, y, layout.editor) ->
        app =
          app
          |> cancel_inline_edit_if_active()
          |> set_focus(:editor)

        case Renderer.editor_completion_rect(app, layout.editor) do
          %{} = comp_rect ->
            if inside_area?(x, y, comp_rect) do
              apply_clicked_completion(app, y, comp_rect)
            else
              place_editor_cursor_at_click(app, x, y, layout.editor)
            end

          nil ->
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

  defp scroll_ai_history(app, ai_area, delta) do
    %{history_area: hist_area} = AIChatPanel.areas(ai_area, input_text: app.ai_input_text)
    tab = active_tab(app)
    data = AIChatPanel.history_data(app, tab, hist_area)
    new_scroll = max(0, min(data.scroll_top + delta, data.max_scroll))
    %{app | ai_history_scroll: new_scroll}
  end

  defp handle_ai_panel_click(app, x, y, ai_area) do
    %{history_area: hist_area, input_area: inp_area} =
      AIChatPanel.areas(ai_area, input_text: app.ai_input_text)

    tab = active_tab(app)

    cond do
      inp_area != nil and inside_area?(x, y, inp_area) ->
        %{app | focus: :ai_panel, ai_panel_focus: :input}

      inside_area?(x, y, hist_area) ->
        data = AIChatPanel.history_data(app, tab, hist_area)
        rel_y = y - hist_area.y - 1

        if rel_y >= 0 and rel_y < data.viewport_h do
          clicked_line = data.scroll_top + rel_y

          case Enum.find(data.turn_ranges, fn {_idx, s, e} ->
                 clicked_line >= s and clicked_line <= e
               end) do
            {msg_idx, _s, _e} ->
              %{app | focus: :ai_panel, ai_panel_focus: :history}
              |> apply_ai_history_turn(msg_idx)

            nil ->
              %{app | focus: :ai_panel, ai_panel_focus: :history}
          end
        else
          %{app | focus: :ai_panel, ai_panel_focus: :history}
        end

      true ->
        %{app | focus: :ai_panel}
    end
  end

  defp handle_modal_click(%__MODULE__{modals: [top | rest]} = app, x, y, modal_area) do
    rel_y = y - modal_area.y - 1

    cond do
      match?(%SQLTabPickerModal{}, top) and rel_y >= 0 ->
        inner_h = max(1, modal_area.height - 2)
        items = SQLTabPickerModal.visible_items(top)

        scroll_top =
          if length(items) > inner_h, do: max(0, top.selected_index - inner_h + 1), else: 0

        case Enum.at(items, scroll_top + rel_y) do
          %{kind: :new_blank} ->
            {_popped, app} = pop_modal(app)
            open_tab(app)

          %{kind: :closed_tab, tab: closed_tab} ->
            {_popped, app} = pop_modal(app)
            reopen_closed_tab(app, closed_tab)

          nil ->
            app
        end

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

      (match?(%ConnectionModal{}, top) or
         match?(%AISettingsModal{}, top) or match?(%UpdateModal{}, top) or
         match?(%ExportModal{}, top) or match?(%ConfirmModal{}, top)) and rel_y >= 0 ->
        handle_form_modal_click(app, top, rest, x, rel_y, modal_area)

      match?(%{type: :confirm_delete_connection}, top) and rel_y == 5 ->
        rel_x = x - modal_area.x - 1
        inner_w = max(2, modal_area.width - 2)

        if rel_x < div(inner_w, 2) do
          handle_key(app, "y")
        else
          handle_key(app, :esc)
        end

      true ->
        app
    end
  end

  defp handle_form_modal_click(app, top, rest, x, rel_y, modal_area) do
    fields =
      modal_area
      |> then(&Strata.UI.Renderer.modal_rendered_info(top, &1))
      |> Map.get(:fields, [])

    {input_fields, button_fields} = Enum.split_with(fields, &(&1.type != :button))
    button_row_y = length(input_fields) + 1

    cond do
      rel_y < length(input_fields) ->
        case Enum.at(input_fields, rel_y) do
          %{type: :info} ->
            app

          %{type: :select, key: key} ->
            updated_top = %{top | focused_field: key}
            open_modal_dropdown(%{app | modals: [updated_top | rest]}, updated_top, key)

          %{key: key} ->
            %{app | modals: [%{top | focused_field: key} | rest]}

          nil ->
            app
        end

      rel_y == button_row_y and button_fields != [] ->
        rel_x = x - modal_area.x - 1
        layout = Strata.UI.Renderer.modal_button_bar_layout(button_fields, modal_area.width - 2)

        case Enum.find(layout.all, fn item -> rel_x >= item.start_x and rel_x <= item.end_x end) do
          %{key: btn_key} -> activate_modal_button(app, top, rest, btn_key)
          nil -> app
        end

      true ->
        app
    end
  end

  defp activate_modal_button(app, %ConnectionModal{} = top, rest, :test_button) do
    updated_top = %{top | focused_field: :test_button}
    test_connection_async(%{app | modals: [updated_top | rest]})
  end

  defp activate_modal_button(app, %AISettingsModal{} = top, rest, :test_button) do
    updated_top = %{top | focused_field: :test_button}
    test_ai_cli_async(%{app | modals: [updated_top | rest]})
  end

  defp activate_modal_button(app, top, rest, btn_key) do
    updated_top = %{top | focused_field: btn_key}
    handle_key(%{app | modals: [updated_top | rest]}, :enter)
  end

  defp collapse_transient_filter_bar(app) do
    if app.filter_bar_transient do
      %{
        app
        | filter_bar_open: false,
          filter_bar_focused: false,
          filter_bar_transient: false,
          filter_dropdown: nil,
          filter_dropdown_search: ""
      }
    else
      %{app | filter_bar_focused: false, filter_dropdown: nil, filter_dropdown_search: ""}
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

          inside_area?(x, y, rects.sort_rect) ->
            if app.filter_dropdown == :sort do
              %{app | filter_dropdown: nil, filter_dropdown_search: ""}
            else
              open_filter_dropdown(app, :sort)
            end

          inside_area?(x, y, rects.col_rect) ->
            if app.filter_dropdown == :column do
              %{app | filter_dropdown: nil, filter_dropdown_search: ""}
            else
              open_filter_dropdown(app, :column)
            end

          inside_area?(x, y, rects.op_rect) ->
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
                    filter_bar_transient: false,
                    filter_bar_focus_part: :value,
                    filter_dropdown: nil
                }
              else
                open_filter_bar(app)
              end

            app
        end

      areas.inspector_area != nil and inside_area?(x, y, areas.inspector_area) ->
        app = collapse_transient_filter_bar(app)
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
        app = collapse_transient_filter_bar(app)
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
                open_inspector(app)
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
      %{key: :"ctrl+←/→"} ->
        cycle_tab(app, 1)

      %{key: :"i/d"} ->
        dispatch_footer_key(app, "i")

      %{key: key} ->
        case map_footer_key(key) do
          nil -> app
          mapped -> dispatch_footer_key(app, mapped)
        end

      nil ->
        app
    end
  end

  defp dispatch_footer_key(app, key) do
    cond do
      app.filter_bar_open and app.filter_bar_focused ->
        handle_filter_bar_key(app, key)

      app.focus == :sidebar and app.sidebar_filter_active ->
        handle_sidebar_filter_key(app, key)

      true ->
        handle_key(app, key)
    end
  end

  defp map_footer_key(k) when k in [:tab, :enter, :esc, :backspace], do: k
  defp map_footer_key(:"ctrl+enter"), do: {:ctrl, "enter"}
  defp map_footer_key(:"ctrl+space"), do: {:ctrl, "space"}
  defp map_footer_key(:"ctrl+p"), do: {:ctrl, "p"}
  defp map_footer_key(:"ctrl+t"), do: {:ctrl, "t"}
  defp map_footer_key(:"ctrl+w"), do: {:ctrl, "w"}
  defp map_footer_key(:"ctrl+s"), do: {:ctrl, "s"}
  defp map_footer_key(:"ctrl+z"), do: {:ctrl, "z"}
  defp map_footer_key(:"ctrl+n"), do: {:ctrl, "n"}
  defp map_footer_key(:"ctrl+g"), do: {:ctrl, "g"}
  defp map_footer_key(:"ctrl+l"), do: {:ctrl, "l"}
  defp map_footer_key(:"ctrl+o"), do: {:ctrl, "o"}

  defp map_footer_key(k)
       when k in [:a, :c, :d, :e, :f, :r, :s, :v, :E, :I, :S, :/, :"?"],
       do: Atom.to_string(k)

  defp map_footer_key(_), do: nil

  @doc """
  Opens the context-aware Actions menu popup (`?` or `Ctrl+P`).
  """
  @spec open_actions_modal(t()) :: t()
  def open_actions_modal(%__MODULE__{} = app) do
    grid = app.datagrid_state || DataGrid.new()

    modal =
      ActionsModal.new(grid, app.active_view,
        focus: app.focus,
        inspector_open: app.inspector_open,
        update_info: app.update_info
      )

    push_modal(app, modal)
  end

  @doc """
  Clears any active column sort on the current `DataGrid` and refreshes filtered/table rows.
  """
  @spec clear_active_sort(t()) :: t()
  def clear_active_sort(%__MODULE__{datagrid_state: %DataGrid{} = grid} = app) do
    if dirty_grid?(grid) do
      %{app | status_message: "⚠️ Commit (Ctrl+S) or Revert (Ctrl+Z) changes before clearing sort"}
    else
      cleared = %{grid | sort_by: nil}

      cond do
        is_map(app.active_filter) ->
          apply_smart_filter(%{app | datagrid_state: cleared})

        app.active_view == :table_view and is_binary(app.selected_table) ->
          refresh_active_table(%{app | datagrid_state: cleared}, force: true)

        true ->
          %{app | datagrid_state: cleared, status_message: "Cleared sort"}
      end
    end
  end

  def clear_active_sort(app), do: app

  defp run_or_refresh_active(%__MODULE__{} = app) do
    if active_tab_kind(app) == :query do
      execute_sql_query(app)
    else
      refresh_active_table(app)
    end
  end

  defp handle_tab_bar_click(app, x, _y, tabs_area) do
    tb = Renderer.tab_bar_layout(app, tabs_area)

    cond do
      tb.new_sql_rect != nil and inside_area?(x, tabs_area.y, tb.new_sql_rect) ->
        request_new_sql_tab(app)

      tb[:ai_sql_rect] != nil and inside_area?(x, tabs_area.y, tb.ai_sql_rect) ->
        open_ai_sql_prompt(app)

      true ->
        case Enum.find(tb.tabs, &inside_area?(x, tabs_area.y, &1.rect)) do
          %{close_rect: close_rect, id: tab_id} ->
            if close_rect != nil and inside_area?(x, tabs_area.y, close_rect) do
              close_tab(app, tab_id)
            else
              switch_tab(app, tab_id)
            end

          nil ->
            app
        end
    end
  end

  defp place_editor_cursor_at_click(app, x, y, editor_area) do
    active_tab = Enum.find(app.tabs, &(&1.id == app.active_tab_id))

    if active_tab do
      content = active_tab.content || ""
      cursor = active_tab.cursor || {0, 0}

      %{gutter_width: gw, code_width: cw, viewport_h: viewport_h} =
        SQLEditor.editor_metrics(content, editor_area)

      layout = SQLEditor.visual_layout(content, cursor, cw)
      scroll_top = SQLEditor.effective_scroll_top(active_tab, editor_area)

      # editor body top border is editor_area.y, so first code row is editor_area.y + 1
      rel_y = y - (editor_area.y + 1)
      rel_x = max(0, x - (editor_area.x + 1 + gw))

      if rel_y >= 0 and rel_y < viewport_h do
        target_v_idx = max(0, min(length(layout.visual_lines) - 1, scroll_top + rel_y))
        target_vl = Enum.at(layout.visual_lines, target_v_idx)
        next_vl = Enum.at(layout.visual_lines, target_v_idx + 1)

        has_next_continuation? =
          next_vl != nil and next_vl.logical_row == target_vl.logical_row and next_vl.continued?

        max_col =
          if has_next_continuation? and target_vl.end_col > target_vl.start_col do
            target_vl.end_col - 1
          else
            target_vl.end_col
          end

        target_row = target_vl.logical_row
        target_col = max(target_vl.start_col, min(max_col, target_vl.start_col + rel_x))

        updated_tabs =
          Enum.map(app.tabs, fn t ->
            if t.id == active_tab.id do
              %{
                t
                | cursor: {target_row, target_col},
                  scroll_offset: scroll_top,
                  completion: %{active?: false, suggestions: [], selected_index: 0, prefix: ""}
              }
            else
              t
            end
          end)

        %{app | tabs: updated_tabs}
      else
        app
      end
    else
      app
    end
  end

  defp apply_clicked_completion(app, y, comp_rect) do
    active = active_tab(app)
    comp = Map.get(active || %{}, :completion, %{})
    suggs = Map.get(comp, :suggestions, [])
    rel_y = y - comp_rect.y - 1
    visible_h = max(1, comp_rect.height - 2)
    sel_idx = Map.get(comp, :selected_index, 0)
    # Match Ratatui List viewport offset when selected item > visible_h
    list_offset = max(0, sel_idx - visible_h + 1)
    idx = list_offset + rel_y

    case Enum.at(suggs, idx) do
      nil ->
        app

      _sug ->
        updated_tabs =
          Enum.map(app.tabs, fn t ->
            if t.id == active.id,
              do: %{t | completion: %{comp | selected_index: idx}},
              else: t
          end)

        SQLEditor.handle_key(%{app | tabs: updated_tabs}, :tab)
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
