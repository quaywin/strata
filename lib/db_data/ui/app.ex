defmodule DBData.UI.App do
  @moduledoc """
  State management for Database TUI interface.
  Manages focus panes, tabbed SQL editor, modal overlays stack, and tree view navigation.
  Integrated with ExRatatui.App behaviour for 60 FPS event-driven TUI.
  """
  use ExRatatui.App

  alias DBData.UI.Components.DataGrid
  alias DBData.UI.Components.LogPane
  alias DBData.UI.Components.Sidebar
  alias DBData.UI.Components.SQLEditor
  alias DBData.UI.Renderer

  @type focus_pane :: :sidebar | :editor | :datagrid | :log

  @type tab :: %{
          id: String.t(),
          name: String.t(),
          content: String.t(),
          cursor: {non_neg_integer(), non_neg_integer()}
        }

  @type t :: %__MODULE__{
          focus: focus_pane(),
          tabs: [tab()],
          active_tab_id: String.t() | nil,
          modals: [map()],
          sidebar_nodes: [map()],
          selected_tree_node_id: String.t() | nil,
          datagrid_state: DataGrid.t() | nil,
          log_state: LogPane.t() | nil,
          mouse_enabled: boolean(),
          window_size: {pos_integer(), pos_integer()},
          status_message: String.t()
        }

  defstruct [
    focus: :sidebar,
    tabs: [],
    active_tab_id: nil,
    modals: [],
    sidebar_nodes: [],
    selected_tree_node_id: nil,
    datagrid_state: nil,
    log_state: nil,
    mouse_enabled: true,
    window_size: {120, 40},
    status_message: "Ready"
  ]

  @panes [:sidebar, :editor, :datagrid, :log]

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
    kind = Map.get(mouse, :kind, :down)

    event =
      case kind do
        :down -> {:click, col, row}
        _ -> {:mouse_event, kind, col, row}
      end

    new_state = handle_mouse(state, event)
    {:noreply, new_state}
  end

  def handle_event(_event, state), do: {:noreply, state}

  @impl true
  def render(state, _frame \\ nil) do
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
      content: "SELECT 1;",
      cursor: {0, 0}
    }

    base = %__MODULE__{
      tabs: [default_tab],
      active_tab_id: "tab_1"
    }

    struct(base, opts)
  end

  @doc """
  Cycles focus between main layout panes (:sidebar -> :editor -> :datagrid -> :log).
  """
  @spec cycle_focus(t(), :next | :prev) :: t()
  def cycle_focus(%__MODULE__{focus: current} = app, direction \\ :next) do
    idx = Enum.find_index(@panes, &(&1 == current)) || 0
    cnt = length(@panes)

    next_idx =
      case direction do
        :next -> rem(idx + 1, cnt)
        :prev -> rem(idx - 1 + cnt, cnt)
      end

    %{app | focus: Enum.at(@panes, next_idx)}
  end

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
  def handle_key(%__MODULE__{modals: [_top | _rest]} = app, :esc) do
    {_popped, app} = pop_modal(app)
    app
  end

  def handle_key(%__MODULE__{} = app, :tab), do: cycle_focus(app, :next)
  def handle_key(%__MODULE__{} = app, :shift_tab), do: cycle_focus(app, :prev)
  def handle_key(%__MODULE__{} = app, {:ctrl, "1"}), do: set_focus(app, :sidebar)
  def handle_key(%__MODULE__{} = app, :f1), do: set_focus(app, :sidebar)
  def handle_key(%__MODULE__{} = app, {:ctrl, "2"}), do: set_focus(app, :editor)
  def handle_key(%__MODULE__{} = app, :f2), do: set_focus(app, :editor)
  def handle_key(%__MODULE__{} = app, {:ctrl, "3"}), do: set_focus(app, :datagrid)
  def handle_key(%__MODULE__{} = app, :f3), do: set_focus(app, :datagrid)
  def handle_key(%__MODULE__{} = app, {:ctrl, "4"}), do: set_focus(app, :log)

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

  def handle_key(%__MODULE__{focus: :log} = app, key) do
    log_state = app.log_state || LogPane.new()
    {app, updated_log_state} = LogPane.handle_key(app, log_state, key)
    %{app | log_state: updated_log_state}
  end

  def handle_key(%__MODULE__{} = app, _key), do: app

  @doc """
  Handles SGR mouse click events to switch focus or interact with UI chunks.
  """
  @spec handle_mouse(t(), any()) :: t()
  def handle_mouse(%__MODULE__{window_size: ws} = app, {:click, x, y}) do
    layout = Renderer.layout(ws)

    cond do
      inside_area?(x, y, layout.sidebar) -> set_focus(app, :sidebar)
      inside_area?(x, y, layout.editor) -> set_focus(app, :editor)
      inside_area?(x, y, layout.datagrid) -> set_focus(app, :datagrid)
      inside_area?(x, y, layout.log) -> set_focus(app, :log)
      true -> app
    end
  end

  def handle_mouse(app, _event), do: app

  defp inside_area?(x, y, %{x: ax, y: ay, width: aw, height: ah}) do
    x >= ax and x < ax + aw and y >= ay and y < ay + ah
  end
end
