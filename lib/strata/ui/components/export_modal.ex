defmodule Strata.UI.Components.ExportModal do
  @moduledoc """
  Modal component for Data Export dialogs.
  Supports formatting and exporting DataGrid results to CSV, JSON, or SQL INSERT statements.
  """

  @export_formats [:csv, :json, :sql]
  @export_scopes [:all, :visible]
  @export_fields [:format, :file_path, :scope, :export_button, :cancel_button]

  defstruct format: :csv,
            file_path: "export.csv",
            scope: :all,
            focused_field: :format,
            cursor_pos: 0,
            status: :idle,
            status_message: nil

  @type t :: %__MODULE__{
          format: :csv | :json | :sql,
          file_path: String.t(),
          scope: :all | :visible,
          focused_field: atom(),
          cursor_pos: non_neg_integer(),
          status: :idle | :success | :error,
          status_message: String.t() | nil
        }

  @doc """
  Initializes an Export modal state.
  """
  def new(opts \\ []) do
    format = Keyword.get(opts, :format, :csv)
    file_path = Keyword.get(opts, :file_path, "export." <> Atom.to_string(format))
    scope = Keyword.get(opts, :scope, :all)
    focused = Keyword.get(opts, :focused_field, :format)

    modal = %__MODULE__{
      format: format,
      file_path: file_path,
      scope: scope,
      focused_field: focused
    }

    %{modal | cursor_pos: field_text_length(modal, focused)}
  end

  @doc """
  Handles keyboard events for field navigation, cursor movement, format/scope cycling, and text input.
  """
  def handle_key(%__MODULE__{} = modal, :tab) do
    next_field = get_next_field(@export_fields, modal.focused_field, 1)
    %{modal | focused_field: next_field, cursor_pos: field_text_length(modal, next_field)}
  end

  def handle_key(%__MODULE__{} = modal, :shift_tab) do
    prev_field = get_next_field(@export_fields, modal.focused_field, -1)
    %{modal | focused_field: prev_field, cursor_pos: field_text_length(modal, prev_field)}
  end

  def handle_key(%__MODULE__{} = modal, :down), do: handle_key(modal, :tab)
  def handle_key(%__MODULE__{} = modal, :up), do: handle_key(modal, :shift_tab)

  # Export Format cycling
  def handle_key(%__MODULE__{focused_field: :format} = modal, key)
      when key in [:right, :space, :enter] do
    idx = Enum.find_index(@export_formats, &(&1 == modal.format)) || 0
    next_fmt = Enum.at(@export_formats, rem(idx + 1, length(@export_formats)))
    %{modal | format: next_fmt, file_path: replace_extension(modal.file_path, next_fmt)}
  end

  def handle_key(%__MODULE__{focused_field: :format} = modal, :left) do
    idx = Enum.find_index(@export_formats, &(&1 == modal.format)) || 0

    prev_fmt =
      Enum.at(@export_formats, rem(idx - 1 + length(@export_formats), length(@export_formats)))

    %{modal | format: prev_fmt, file_path: replace_extension(modal.file_path, prev_fmt)}
  end

  # Export Scope toggle
  def handle_key(%__MODULE__{focused_field: :scope} = modal, key)
      when key in [:space, :enter, :right, :left] do
    next_scope = if modal.scope == :all, do: :visible, else: :all
    %{modal | scope: next_scope}
  end

  # Action buttons & quick submit
  def handle_key(%__MODULE__{focused_field: :export_button} = modal, key)
      when key in [:enter, :space] do
    {:apply, {:export, modal.format, modal.file_path, modal.scope}, modal}
  end

  def handle_key(%__MODULE__{focused_field: :cancel_button} = modal, key)
      when key in [:enter, :space] do
    {:cancel, modal}
  end

  def handle_key(%__MODULE__{focused_field: :file_path} = modal, :enter) do
    {:apply, {:export, modal.format, modal.file_path, modal.scope}, modal}
  end

  # Cursor navigation in text fields
  def handle_key(%__MODULE__{focused_field: :file_path} = modal, :left) do
    len = field_text_length(modal, :file_path)
    pos = min(modal.cursor_pos || len, len)
    %{modal | cursor_pos: max(0, pos - 1)}
  end

  def handle_key(%__MODULE__{focused_field: :file_path} = modal, :right) do
    len = field_text_length(modal, :file_path)
    pos = min(modal.cursor_pos || len, len)
    %{modal | cursor_pos: min(len, pos + 1)}
  end

  def handle_key(%__MODULE__{focused_field: :file_path} = modal, :home),
    do: %{modal | cursor_pos: 0}

  def handle_key(%__MODULE__{focused_field: :file_path} = modal, :end),
    do: %{modal | cursor_pos: field_text_length(modal, :file_path)}

  # Clear active field (Ctrl+U / Ctrl+K)
  def handle_key(%__MODULE__{focused_field: :file_path} = modal, key)
      when key in [{:ctrl, "u"}, {:ctrl, "k"}] do
    %{modal | file_path: "", cursor_pos: 0}
  end

  # Backspace and Delete handling at cursor position
  def handle_key(%__MODULE__{focused_field: :file_path} = modal, :backspace) do
    val_str = to_string(modal.file_path || "")
    pos = clamp_cursor(modal.cursor_pos, val_str)

    if pos == 0 do
      modal
    else
      {left, right} = String.split_at(val_str, pos)
      new_str = String.slice(left, 0, String.length(left) - 1) <> right
      %{modal | file_path: new_str, cursor_pos: max(0, pos - 1)}
    end
  end

  def handle_key(%__MODULE__{focused_field: :file_path} = modal, :delete) do
    val_str = to_string(modal.file_path || "")
    pos = clamp_cursor(modal.cursor_pos, val_str)

    if pos >= String.length(val_str) do
      modal
    else
      {left, right} = String.split_at(val_str, pos)
      new_str = left <> String.slice(right, 1, String.length(right))
      %{modal | file_path: new_str, cursor_pos: pos}
    end
  end

  # Text entry / paste handling at cursor position
  def handle_key(%__MODULE__{focused_field: :file_path} = modal, key) when is_binary(key) do
    val_str = to_string(modal.file_path || "")
    pos = clamp_cursor(modal.cursor_pos, val_str)
    {left, right} = String.split_at(val_str, pos)
    candidate = left <> key <> right
    %{modal | file_path: candidate, cursor_pos: pos + String.length(key)}
  end

  def handle_key(modal, _key), do: modal

  @doc """
  Formats columns and rows data according to export options (CSV, JSON, or SQL).
  """
  def format_export(%__MODULE__{} = modal, columns, rows, opts \\ []) do
    table_name = Keyword.get(opts, :table_name, "export_table")

    case modal.format do
      :csv ->
        header = Enum.join(columns, ",") <> "\n"

        row_lines =
          Enum.map(rows, fn row ->
            Enum.map(row, &format_csv_field/1) |> Enum.join(",")
          end)

        header <> Enum.join(row_lines, "\n") <> if(row_lines != [], do: "\n", else: "")

      :json ->
        maps =
          Enum.map(rows, fn row ->
            Enum.zip(columns, row) |> Enum.into(%{})
          end)

        Jason.encode!(maps, pretty: true)

      :sql ->
        cols_str = Enum.join(columns, ", ")

        statements =
          Enum.map(rows, fn row ->
            vals_str = Enum.map(row, &format_sql_value/1) |> Enum.join(", ")
            "INSERT INTO #{table_name} (#{cols_str}) VALUES (#{vals_str});"
          end)

        Enum.join(statements, "\n") <> if(statements != [], do: "\n", else: "")
    end
  end

  @doc """
  Renders structured map representation of the export modal for TUI rendering.
  """
  def render(%__MODULE__{} = modal, area) do
    path_display =
      display_with_cursor(
        modal.file_path,
        modal.focused_field == :file_path,
        modal.cursor_pos,
        "export.csv"
      )

    fields = [
      %{
        label: "Format",
        key: :format,
        value: Atom.to_string(modal.format),
        type: :select,
        options: Enum.map(@export_formats, &Atom.to_string/1)
      },
      %{label: "File Path", key: :file_path, value: path_display, type: :text},
      %{
        label: "Scope",
        key: :scope,
        value: Atom.to_string(modal.scope),
        type: :select,
        options: Enum.map(@export_scopes, &Atom.to_string/1)
      },
      %{label: "[ Export Data ]", key: :export_button, type: :button},
      %{label: "[ Cancel ]", key: :cancel_button, type: :button}
    ]

    %{
      title: "EXPORT DATA GRID",
      area: area,
      focused_field: modal.focused_field,
      fields: fields,
      status: modal.status,
      status_message:
        modal.status_message || "Tips: ←/→ Format/Scope · Ctrl+V Paste path · Enter Export"
    }
  end

  defp replace_extension(file_path, format) do
    ext = Atom.to_string(format)

    if String.contains?(file_path, ".") do
      Path.rootname(file_path) <> "." <> ext
    else
      file_path <> "." <> ext
    end
  end

  defp field_text_length(modal, :file_path), do: String.length(to_string(modal.file_path || ""))
  defp field_text_length(_modal, _field), do: 0

  defp clamp_cursor(pos, str) do
    len = String.length(str)
    pos = pos || len
    max(0, min(len, pos))
  end

  defp display_with_cursor(val, true, cursor_pos, placeholder) do
    str = to_string(val || "")
    pos = clamp_cursor(cursor_pos, str)
    {left, right} = String.split_at(str, pos)

    if str == "" do
      "▏ (" <> placeholder <> ")"
    else
      left <> "▏" <> right
    end
  end

  defp display_with_cursor(val, false, _cursor_pos, placeholder) do
    str = to_string(val || "")
    if str == "", do: "(#{placeholder})", else: str
  end

  defp get_next_field(fields, current, delta) do
    idx = Enum.find_index(fields, &(&1 == current)) || 0
    cnt = length(fields)
    Enum.at(fields, rem(idx + delta + cnt, cnt))
  end

  defp format_csv_field(nil), do: ""

  defp format_csv_field(val) do
    str = to_string(val)

    if String.contains?(str, [",", "\"", "\n"]) do
      "\"" <> String.replace(str, "\"", "\"\"") <> "\""
    else
      str
    end
  end

  defp format_sql_value(nil), do: "NULL"
  defp format_sql_value(val) when is_integer(val) or is_float(val), do: to_string(val)
  defp format_sql_value(val) when is_boolean(val), do: if(val, do: "TRUE", else: "FALSE")

  defp format_sql_value(val) do
    str = to_string(val)
    "'" <> String.replace(str, "'", "''") <> "'"
  end
end
