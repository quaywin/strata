defmodule DBData.UI.Components.LogPane do
  @moduledoc """
  Execution Log Console component displaying real-time query logs, timestamps,
  error levels, and supporting auto-scroll & keyboard scrolling.
  """

  defstruct [
    entries: [],
    scroll_offset: 0,
    auto_scroll?: true
  ]

  @type entry :: %{
          timestamp: String.t(),
          level: :info | :error | :warn | :debug,
          message: String.t(),
          duration_ms: number() | nil,
          rows_affected: non_neg_integer() | nil
        }

  @type t :: %__MODULE__{
          entries: [entry()],
          scroll_offset: non_neg_integer(),
          auto_scroll?: boolean()
        }

  @doc """
  Creates a new LogPane struct.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      entries: Keyword.get(opts, :entries, []),
      scroll_offset: Keyword.get(opts, :scroll_offset, 0),
      auto_scroll?: Keyword.get(opts, :auto_scroll?, true)
    }
  end

  @doc """
  Appends a log entry to LogPane state.
  """
  @spec add_entry(t(), map() | keyword()) :: t()
  def add_entry(%__MODULE__{entries: entries, auto_scroll?: auto_scroll?} = state, opts) do
    opts_map = if is_list(opts), do: Map.new(opts), else: opts

    timestamp =
      Map.get(opts_map, :timestamp) ||
        (Time.utc_now() |> Time.truncate(:second) |> Time.to_string())

    level = Map.get(opts_map, :level, :info)
    message = Map.get(opts_map, :message, "")
    duration_ms = Map.get(opts_map, :duration_ms)
    rows_affected = Map.get(opts_map, :rows_affected)

    entry = %{
      timestamp: timestamp,
      level: level,
      message: message,
      duration_ms: duration_ms,
      rows_affected: rows_affected
    }

    updated_entries = entries ++ [entry]

    new_offset =
      if auto_scroll? do
        max(0, length(updated_entries) - 1)
      else
        state.scroll_offset
      end

    %{state | entries: updated_entries, scroll_offset: new_offset}
  end

  @doc """
  Adjusts log pane scroll offset based on direction.
  """
  @spec scroll(t(), atom()) :: t()
  def scroll(%__MODULE__{entries: entries} = state, direction) do
    total = length(entries)

    case direction do
      :up ->
        %{state | scroll_offset: max(0, state.scroll_offset - 1), auto_scroll?: false}

      :down ->
        new_offset = min(max(0, total - 1), state.scroll_offset + 1)
        auto? = new_offset >= max(0, total - 1)
        %{state | scroll_offset: new_offset, auto_scroll?: auto?}

      :page_up ->
        %{state | scroll_offset: max(0, state.scroll_offset - 5), auto_scroll?: false}

      :page_down ->
        new_offset = min(max(0, total - 1), state.scroll_offset + 5)
        auto? = new_offset >= max(0, total - 1)
        %{state | scroll_offset: new_offset, auto_scroll?: auto?}

      :top ->
        %{state | scroll_offset: 0, auto_scroll?: false}

      :home ->
        %{state | scroll_offset: 0, auto_scroll?: false}

      :bottom ->
        %{state | scroll_offset: max(0, total - 1), auto_scroll?: true}

      :end ->
        %{state | scroll_offset: max(0, total - 1), auto_scroll?: true}

      _other ->
        state
    end
  end

  @doc """
  Handles keyboard events when LogPane is active.
  """
  def handle_key(app, %__MODULE__{} = log_state, key) do
    updated_state =
      case key do
        dir when dir in [:up, :down, :page_up, :page_down, :home, :end, :top, :bottom] ->
          scroll(log_state, dir)

        _other ->
          log_state
      end

    {app, updated_state}
  end

  @doc """
  Renders query log console data structure for given area.
  """
  def render(_app, area, %__MODULE__{} = log_state \\ new()) do
    lines =
      Enum.map(log_state.entries, fn entry ->
        level_str = String.upcase(to_string(entry.level))
        duration_str = if entry.duration_ms, do: " (#{entry.duration_ms}ms)", else: ""
        rows_str = if entry.rows_affected, do: " [#{entry.rows_affected} rows]", else: ""

        text = "[#{entry.timestamp}] [#{level_str}] #{entry.message}#{duration_str}#{rows_str}"

        %{
          text: text,
          level: entry.level,
          timestamp: entry.timestamp
        }
      end)

    %{
      title: "QUERY LOGS & CONSOLE STATS",
      area: area,
      auto_scroll?: log_state.auto_scroll?,
      scroll_offset: log_state.scroll_offset,
      lines: lines
    }
  end
end
