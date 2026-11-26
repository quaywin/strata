defmodule Strata.UI.Components.CellDetailModal do
  @moduledoc """
  Cell Detail Inspector popup for viewing data grid cell content.
  Auto-detects JSON structures and pretty-prints them.
  Supports 16-byte UUID decoding, format toggling (:json, :text, :raw), line wrapping, and scrolling.
  """

  @formats [:json, :text, :raw]

  defstruct column: nil,
            row_index: nil,
            raw_value: nil,
            format: :text,
            detected_type: :text,
            formatted_value: "",
            scroll_offset: 0,
            wrap_lines: true

  @type t :: %__MODULE__{
          column: String.t() | nil,
          row_index: integer() | nil,
          raw_value: any(),
          format: :json | :text | :raw,
          detected_type: :json | :text | nil | :primitive | :uuid | :binary,
          formatted_value: String.t(),
          scroll_offset: non_neg_integer(),
          wrap_lines: boolean()
        }

  @doc """
  Initializes a CellDetailModal with the target cell value and optional metadata.
  """
  def new(value, opts \\ []) do
    column = Keyword.get(opts, :column)
    row_index = Keyword.get(opts, :row_index)
    wrap_lines = Keyword.get(opts, :wrap_lines, true)

    {detected_type, format, formatted_val} = analyze_and_format(value)

    %__MODULE__{
      column: column,
      row_index: row_index,
      raw_value: value,
      format: format,
      detected_type: detected_type,
      formatted_value: formatted_val,
      scroll_offset: 0,
      wrap_lines: wrap_lines
    }
  end

  @doc """
  Detects whether a cell value is JSON or plain text.
  """
  def detect_format(value) do
    case analyze_and_format(value) do
      {:json, _fmt, _val} -> :json
      _ -> :text
    end
  end

  @doc """
  Handles keys for scrolling, format toggling, and line wrapping.
  """
  def handle_key(%__MODULE__{} = modal, key) when key in ["f", "F", :tab] do
    idx = Enum.find_index(@formats, &(&1 == modal.format)) || 0
    next_fmt = Enum.at(@formats, rem(idx + 1, length(@formats)))
    new_formatted = format_value(modal.raw_value, next_fmt)

    %{modal | format: next_fmt, formatted_value: new_formatted}
  end

  def handle_key(%__MODULE__{} = modal, "w") do
    %{modal | wrap_lines: not modal.wrap_lines}
  end

  def handle_key(%__MODULE__{} = modal, key) when key in [:down, "j"] do
    %{modal | scroll_offset: modal.scroll_offset + 1}
  end

  def handle_key(%__MODULE__{} = modal, key) when key in [:up, "k"] do
    %{modal | scroll_offset: max(0, modal.scroll_offset - 1)}
  end

  def handle_key(%__MODULE__{} = modal, :page_down) do
    %{modal | scroll_offset: modal.scroll_offset + 10}
  end

  def handle_key(%__MODULE__{} = modal, :page_up) do
    %{modal | scroll_offset: max(0, modal.scroll_offset - 10)}
  end

  def handle_key(modal, _key), do: modal

  @doc """
  Renders structured map representation for rendering in Ratatui/TUI.
  """
  def render(%__MODULE__{} = modal, area) do
    all_lines = String.split(modal.formatted_value, "\n")
    inner_h = max(1, Map.get(area, :height, 20) - 4)
    max_scroll = max(0, length(all_lines) - inner_h)
    clamped_scroll = min(modal.scroll_offset, max_scroll)
    visible_lines = all_lines |> Enum.drop(clamped_scroll) |> Enum.take(inner_h)

    title =
      if modal.column do
        "🔍 CELL INSPECTOR — [" <> to_string(modal.column) <> "]"
      else
        "🔍 CELL INSPECTOR"
      end

    content_str = Enum.join(visible_lines, "\n")

    status_hint =
      "\n───── [ Format: #{modal.format} (f) | Wrap: #{modal.wrap_lines} (w) | c: Copy | ↑/↓: Scroll | Esc: Close ] ─────"

    %{
      title: title,
      area: area,
      column: modal.column,
      row_index: modal.row_index,
      format: modal.format,
      detected_type: modal.detected_type,
      content: content_str <> status_hint,
      lines: visible_lines,
      total_lines: length(all_lines),
      scroll_offset: clamped_scroll,
      wrap_lines: modal.wrap_lines
    }
  end

  defp analyze_and_format(nil), do: {nil, :text, "<NULL>"}

  defp analyze_and_format(value) when is_map(value) or is_list(value) do
    case Jason.encode(value, pretty: true) do
      {:ok, json_str} -> {:json, :json, json_str}
      _ -> {:primitive, :text, inspect(value)}
    end
  end

  defp analyze_and_format(value) when is_binary(value) do
    case Strata.Formatter.decode_json_pretty(value) do
      {:ok, json_str} ->
        {:json, :json, json_str}

      :error ->
        cond do
          String.printable?(value) ->
            {:text, :text, value}

          byte_size(value) == 16 ->
            {:uuid, :text, Strata.Formatter.format_uuid(value)}

          true ->
            {:binary, :raw, Strata.Formatter.format_cell_detail(value)}
        end
    end
  end

  defp analyze_and_format(value) do
    {:primitive, :text, to_string(value)}
  end

  defp format_value(value, :raw) do
    inspect(value)
  end

  defp format_value(value, :json) do
    case analyze_and_format(value) do
      {_type, _fmt, val} -> val
    end
  end

  defp format_value(value, :text) do
    cond do
      is_nil(value) -> "<NULL>"
      is_binary(value) -> Strata.Formatter.format_cell_detail(value)
      true -> to_string(value)
    end
  end
end
