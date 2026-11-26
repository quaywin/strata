defmodule Strata.UI.Components.FilterExportModal do
  @moduledoc """
  Unified Modal component for Data Grid Filter/Sort dialogs and Data Export dialogs.
  Supports building SQL WHERE/ORDER BY/LIMIT clauses and formatting data export to CSV, JSON, or SQL INSERTs.
  """

  @export_formats [:csv, :json, :sql]
  @export_scopes [:all, :current_page]

  @filter_fields [:where, :order_by, :limit, :apply_button, :clear_button, :cancel_button]
  @export_fields [:format, :file_path, :scope, :export_button, :cancel_button]

  defstruct [
    mode: :filter,
    # Filter mode fields
    where_clause: "",
    order_by_clause: "",
    limit: nil,
    columns: [],
    selected_column: nil,
    # Export mode fields
    format: :csv,
    file_path: "export.csv",
    scope: :all,
    # Focus, cursor, and status
    focused_field: :where,
    cursor_pos: 0,
    status: :idle,
    status_message: nil
  ]

  @type t :: %__MODULE__{
          mode: :filter | :export,
          where_clause: String.t(),
          order_by_clause: String.t(),
          limit: integer() | nil,
          columns: [String.t()],
          selected_column: String.t() | nil,
          format: :csv | :json | :sql,
          file_path: String.t(),
          scope: :all | :current_page,
          focused_field: atom(),
          cursor_pos: non_neg_integer(),
          status: :idle | :success | :error,
          status_message: String.t() | nil
        }

  @doc """
  Initializes a new filter or export modal.
  """
  def new(mode, opts \\ []) when mode in [:filter, :export] do
    case mode do
      :filter -> new_filter(opts)
      :export -> new_export(opts)
    end
  end

  @doc """
  Initializes a Filter modal state.
  """
  def new_filter(opts \\ []) do
    where = Keyword.get(opts, :where, "")
    order_by = Keyword.get(opts, :order_by, "")
    limit = Keyword.get(opts, :limit)
    columns = Keyword.get(opts, :columns, [])
    selected_column = Keyword.get(opts, :selected_column)
    focused = Keyword.get(opts, :focused_field, :where)

    modal = %__MODULE__{
      mode: :filter,
      where_clause: where,
      order_by_clause: order_by,
      limit: limit,
      columns: columns,
      selected_column: selected_column,
      focused_field: focused
    }

    %{modal | cursor_pos: field_text_length(modal, focused)}
  end

  @doc """
  Initializes an Export modal state.
  """
  def new_export(opts \\ []) do
    format = Keyword.get(opts, :format, :csv)
    file_path = Keyword.get(opts, :file_path, "export." <> Atom.to_string(format))
    scope = Keyword.get(opts, :scope, :all)
    focused = Keyword.get(opts, :focused_field, :format)

    modal = %__MODULE__{
      mode: :export,
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
    fields = fields_for_mode(modal.mode)
    next_field = get_next_field(fields, modal.focused_field, 1)
    %{modal | focused_field: next_field, cursor_pos: field_text_length(modal, next_field)}
  end

  def handle_key(%__MODULE__{} = modal, :shift_tab) do
    fields = fields_for_mode(modal.mode)
    prev_field = get_next_field(fields, modal.focused_field, -1)
    %{modal | focused_field: prev_field, cursor_pos: field_text_length(modal, prev_field)}
  end

  def handle_key(%__MODULE__{} = modal, :down) do
    handle_key(modal, :tab)
  end

  def handle_key(%__MODULE__{} = modal, :up) do
    handle_key(modal, :shift_tab)
  end

  # Export Format cycling
  def handle_key(%__MODULE__{mode: :export, focused_field: :format} = modal, key)
      when key in [:right, :space, :enter] do
    idx = Enum.find_index(@export_formats, &(&1 == modal.format)) || 0
    next_fmt = Enum.at(@export_formats, rem(idx + 1, length(@export_formats)))
    new_ext = Atom.to_string(next_fmt)

    new_path =
      if String.contains?(modal.file_path, ".") do
        Path.rootname(modal.file_path) <> "." <> new_ext
      else
        modal.file_path <> "." <> new_ext
      end

    %{modal | format: next_fmt, file_path: new_path}
  end

  def handle_key(%__MODULE__{mode: :export, focused_field: :format} = modal, key)
      when key in [:left] do
    idx = Enum.find_index(@export_formats, &(&1 == modal.format)) || 0
    prev_fmt = Enum.at(@export_formats, rem(idx - 1 + length(@export_formats), length(@export_formats)))
    new_ext = Atom.to_string(prev_fmt)

    new_path =
      if String.contains?(modal.file_path, ".") do
        Path.rootname(modal.file_path) <> "." <> new_ext
      else
        modal.file_path <> "." <> new_ext
      end

    %{modal | format: prev_fmt, file_path: new_path}
  end

  # Export Scope toggle
  def handle_key(%__MODULE__{mode: :export, focused_field: :scope} = modal, key)
      when key in [:space, :enter, :right, :left] do
    next_scope = if modal.scope == :all, do: :current_page, else: :all
    %{modal | scope: next_scope}
  end

  # Action buttons & quick submit
  def handle_key(%__MODULE__{mode: :filter, focused_field: :apply_button} = modal, key)
      when key in [:enter, :space] do
    {:apply, {:filter, modal.where_clause, modal.order_by_clause, modal.limit}, modal}
  end

  def handle_key(%__MODULE__{mode: :filter, focused_field: :clear_button} = modal, key)
      when key in [:enter, :space] do
    cleared = %{modal | where_clause: "", order_by_clause: "", limit: nil, cursor_pos: 0}
    {:apply, {:filter, "", "", nil}, cleared}
  end

  def handle_key(%__MODULE__{mode: :filter}, {:ctrl, "l"}) do
    cleared = %{modal_reset_filter() | columns: []}
    {:apply, {:filter, "", "", nil}, cleared}
  end

  def handle_key(%__MODULE__{mode: :export, focused_field: :export_button} = modal, key)
      when key in [:enter, :space] do
    {:apply, {:export, modal.format, modal.file_path, modal.scope}, modal}
  end

  def handle_key(%__MODULE__{focused_field: :cancel_button} = modal, key)
      when key in [:enter, :space] do
    {:cancel, modal}
  end

  def handle_key(%__MODULE__{mode: :filter, focused_field: field} = modal, :enter)
      when field in [:where, :order_by, :limit] do
    {:apply, {:filter, modal.where_clause, modal.order_by_clause, modal.limit}, modal}
  end

  def handle_key(%__MODULE__{mode: :export, focused_field: :file_path} = modal, :enter) do
    {:apply, {:export, modal.format, modal.file_path, modal.scope}, modal}
  end

  # Cursor navigation in text fields
  def handle_key(%__MODULE__{focused_field: field} = modal, :left)
      when field in [:where, :order_by, :limit, :file_path] do
    len = field_text_length(modal, field)
    pos = min(modal.cursor_pos || len, len)
    %{modal | cursor_pos: max(0, pos - 1)}
  end

  def handle_key(%__MODULE__{focused_field: field} = modal, :right)
      when field in [:where, :order_by, :limit, :file_path] do
    len = field_text_length(modal, field)
    pos = min(modal.cursor_pos || len, len)
    %{modal | cursor_pos: min(len, pos + 1)}
  end

  def handle_key(%__MODULE__{focused_field: field} = modal, :home)
      when field in [:where, :order_by, :limit, :file_path] do
    %{modal | cursor_pos: 0}
  end

  def handle_key(%__MODULE__{focused_field: field} = modal, :end)
      when field in [:where, :order_by, :limit, :file_path] do
    %{modal | cursor_pos: field_text_length(modal, field)}
  end

  # Clear active field (Ctrl+U / Ctrl+K)
  def handle_key(%__MODULE__{focused_field: field} = modal, key)
      when key in [{:ctrl, "u"}, {:ctrl, "k"}] and field in [:where, :order_by, :limit, :file_path] do
    empty_val = if field == :limit, do: nil, else: ""

    modal
    |> Map.put(field_key(field), empty_val)
    |> Map.put(:cursor_pos, 0)
  end

  # Backspace and Delete handling at cursor position
  def handle_key(%__MODULE__{focused_field: field} = modal, :backspace)
      when field in [:where, :order_by, :limit, :file_path] do
    val_str = field_text(modal, field)
    pos = clamp_cursor(modal.cursor_pos, val_str)

    if pos == 0 do
      modal
    else
      {left, right} = String.split_at(val_str, pos)
      new_str = String.slice(left, 0, String.length(left) - 1) <> right
      update_text_field(modal, field, new_str, pos - 1)
    end
  end

  def handle_key(%__MODULE__{focused_field: field} = modal, :delete)
      when field in [:where, :order_by, :limit, :file_path] do
    val_str = field_text(modal, field)
    pos = clamp_cursor(modal.cursor_pos, val_str)

    if pos >= String.length(val_str) do
      modal
    else
      {left, right} = String.split_at(val_str, pos)
      new_str = left <> String.slice(right, 1, String.length(right))
      update_text_field(modal, field, new_str, pos)
    end
  end

  # Text entry / paste handling at cursor position
  def handle_key(%__MODULE__{focused_field: field} = modal, key)
      when is_binary(key) and field in [:where, :order_by, :limit, :file_path] do
    val_str = field_text(modal, field)
    pos = clamp_cursor(modal.cursor_pos, val_str)
    {left, right} = String.split_at(val_str, pos)
    candidate = left <> key <> right
    update_text_field(modal, field, candidate, pos + String.length(key))
  end

  def handle_key(modal, _key), do: modal

  @doc """
  Constructs a full SQL SELECT statement from filter options.
  """
  def build_filter_sql(%__MODULE__{mode: :filter} = modal, base_table) when is_binary(base_table) do
    clauses = []

    clauses =
      if modal.where_clause != "" && String.trim(modal.where_clause) != "" do
        clauses ++ ["WHERE " <> String.trim(modal.where_clause)]
      else
        clauses
      end

    clauses =
      if modal.order_by_clause != "" && String.trim(modal.order_by_clause) != "" do
        clauses ++ ["ORDER BY " <> String.trim(modal.order_by_clause)]
      else
        clauses
      end

    clauses =
      if modal.limit && modal.limit > 0 do
        clauses ++ ["LIMIT " <> Integer.to_string(modal.limit)]
      else
        clauses
      end

    base_sql = "SELECT * FROM " <> base_table

    if clauses == [] do
      base_sql
    else
      base_sql <> " " <> Enum.join(clauses, " ")
    end
  end

  @doc """
  Formats columns and rows data according to export options (CSV, JSON, or SQL).
  """
  def format_export(%__MODULE__{mode: :export} = modal, columns, rows, opts \\ []) do
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
  Renders structured map representation of the modal for TUI rendering.
  """
  def render(%__MODULE__{mode: :filter} = modal, area) do
    where_display = display_with_cursor(modal.where_clause, modal.focused_field == :where, modal.cursor_pos, "e.g. status = 'active' AND id > 10")
    order_display = display_with_cursor(modal.order_by_clause, modal.focused_field == :order_by, modal.cursor_pos, "e.g. created_at DESC")

    limit_raw = if modal.limit, do: Integer.to_string(modal.limit), else: ""
    limit_display = display_with_cursor(limit_raw, modal.focused_field == :limit, modal.cursor_pos, "e.g. 100")

    fields = [
      %{label: "WHERE Clause", key: :where, value: where_display, type: :text},
      %{label: "ORDER BY Clause", key: :order_by, value: order_display, type: :text},
      %{label: "LIMIT Records", key: :limit, value: limit_display, type: :text},
      %{label: "[ Apply Filter ]", key: :apply_button, type: :button},
      %{label: "[ Clear Filter ]", key: :clear_button, type: :button},
      %{label: "[ Cancel ]", key: :cancel_button, type: :button}
    ]

    cols_hint =
      if modal.columns != [] do
        cols_preview = modal.columns |> Enum.take(8) |> Enum.join(", ")
        suffix = if length(modal.columns) > 8, do: ", ...", else: ""
        "Columns: #{cols_preview}#{suffix}\n  "
      else
        ""
      end

    tips = cols_hint <> "Tips: Enter Apply · ←/→ Cursor · Ctrl+V Paste · Ctrl+U Clear line · Ctrl+L Reset"

    %{
      title: "FILTER & SORT DATA",
      mode: :filter,
      area: area,
      focused_field: modal.focused_field,
      fields: fields,
      status: modal.status,
      status_message: modal.status_message || tips
    }
  end

  def render(%__MODULE__{mode: :export} = modal, area) do
    path_display = display_with_cursor(modal.file_path, modal.focused_field == :file_path, modal.cursor_pos, "export.csv")

    fields = [
      %{
        label: "Format",
        key: :format,
        value: Atom.to_string(modal.format),
        type: :select,
        options: Enum.map(@export_formats, &Atom.to_string/1)
      },
      %{label: "File Path", key: :file_path, value: path_display, type: :text},
      %{label: "Scope", key: :scope, value: Atom.to_string(modal.scope), type: :select, options: Enum.map(@export_scopes, &Atom.to_string/1)},
      %{label: "[ Export Data ]", key: :export_button, type: :button},
      %{label: "[ Cancel ]", key: :cancel_button, type: :button}
    ]

    %{
      title: "EXPORT DATA GRID",
      mode: :export,
      area: area,
      focused_field: modal.focused_field,
      fields: fields,
      status: modal.status,
      status_message: modal.status_message || "Tips: ←/→ Format/Scope · Ctrl+V Paste path · Enter Export"
    }
  end

  defp modal_reset_filter, do: %__MODULE__{mode: :filter, focused_field: :where, cursor_pos: 0}

  defp fields_for_mode(:filter), do: @filter_fields
  defp fields_for_mode(:export), do: @export_fields

  defp field_key(:where), do: :where_clause
  defp field_key(:order_by), do: :order_by_clause
  defp field_key(:limit), do: :limit
  defp field_key(:file_path), do: :file_path

  defp field_text(modal, :limit) do
    if is_integer(modal.limit), do: Integer.to_string(modal.limit), else: ""
  end

  defp field_text(modal, field) when field in [:where, :order_by, :file_path] do
    to_string(Map.get(modal, field_key(field)) || "")
  end

  defp field_text(_modal, _field), do: ""

  defp field_text_length(modal, field), do: String.length(field_text(modal, field))

  defp clamp_cursor(pos, str) do
    len = String.length(str)
    pos = pos || len
    max(0, min(len, pos))
  end

  defp update_text_field(modal, :limit, new_str, new_pos) do
    trimmed = String.trim(new_str)

    cond do
      trimmed == "" ->
        %{modal | limit: nil, cursor_pos: 0}

      match?({i, ""} when i >= 0, Integer.parse(trimmed)) ->
        {i, ""} = Integer.parse(trimmed)
        %{modal | limit: i, cursor_pos: min(new_pos, String.length(trimmed))}

      true ->
        modal
    end
  end

  defp update_text_field(modal, field, new_str, new_pos) do
    modal
    |> Map.put(field_key(field), new_str)
    |> Map.put(:cursor_pos, max(0, min(String.length(new_str), new_pos)))
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
