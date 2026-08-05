defmodule Strata.UI.Components.FilterExportModal do
  @moduledoc """
  Unified Modal component for Data Grid Filter/Sort dialogs and Data Export dialogs.
  Supports building SQL WHERE/ORDER BY/LIMIT clauses and formatting data export to CSV, JSON, or SQL INSERTs.
  """

  @export_formats [:csv, :json, :sql]
  @export_scopes [:all, :current_page]

  @filter_fields [:where, :order_by, :limit, :apply_button, :cancel_button]
  @export_fields [:format, :file_path, :scope, :export_button, :cancel_button]

  defstruct [
    mode: :filter,
    # Filter mode fields
    where_clause: "",
    order_by_clause: "",
    limit: nil,
    # Export mode fields
    format: :csv,
    file_path: "export.csv",
    scope: :all,
    # Focus and status
    focused_field: :where,
    status: :idle,
    status_message: nil
  ]

  @type t :: %__MODULE__{
          mode: :filter | :export,
          where_clause: String.t(),
          order_by_clause: String.t(),
          limit: integer() | nil,
          format: :csv | :json | :sql,
          file_path: String.t(),
          scope: :all | :current_page,
          focused_field: atom(),
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

    %__MODULE__{
      mode: :filter,
      where_clause: where,
      order_by_clause: order_by,
      limit: limit,
      focused_field: :where
    }
  end

  @doc """
  Initializes an Export modal state.
  """
  def new_export(opts \\ []) do
    format = Keyword.get(opts, :format, :csv)
    file_path = Keyword.get(opts, :file_path, "export." <> Atom.to_string(format))
    scope = Keyword.get(opts, :scope, :all)

    %__MODULE__{
      mode: :export,
      format: format,
      file_path: file_path,
      scope: scope,
      focused_field: :format
    }
  end

  @doc """
  Handles keyboard events for field navigation, format/scope cycling, and text input.
  """
  def handle_key(%__MODULE__{} = modal, :tab) do
    fields = fields_for_mode(modal.mode)
    next_field = get_next_field(fields, modal.focused_field, 1)
    %{modal | focused_field: next_field}
  end

  def handle_key(%__MODULE__{} = modal, :shift_tab) do
    fields = fields_for_mode(modal.mode)
    prev_field = get_next_field(fields, modal.focused_field, -1)
    %{modal | focused_field: prev_field}
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

  # Backspace handling
  def handle_key(%__MODULE__{focused_field: field} = modal, :backspace)
      when field in [:where, :order_by, :limit, :file_path] do
    val = Map.get(modal, field_key(field))
    val_str = if is_integer(val), do: Integer.to_string(val), else: to_string(val || "")
    new_val_str = String.slice(val_str, 0, max(0, String.length(val_str) - 1))

    new_val =
      if field == :limit do
        case Integer.parse(new_val_str) do
          {i, ""} -> i
          _ -> nil
        end
      else
        new_val_str
      end

    Map.put(modal, field_key(field), new_val)
  end

  # Text entry handling
  def handle_key(%__MODULE__{focused_field: field} = modal, key)
      when is_binary(key) and field in [:where, :order_by, :limit, :file_path] do
    val = Map.get(modal, field_key(field))

    if field == :limit do
      val_str = Integer.to_string(val || 0) <> key

      case Integer.parse(val_str) do
        {i, ""} -> %{modal | limit: i}
        _ -> modal
      end
    else
      val_str = (val || "") <> key
      Map.put(modal, field_key(field), val_str)
    end
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
    fields = [
      %{label: "WHERE Clause", key: :where, value: modal.where_clause, type: :text},
      %{label: "ORDER BY Clause", key: :order_by, value: modal.order_by_clause, type: :text},
      %{
        label: "LIMIT Records",
        key: :limit,
        value: if(modal.limit, do: Integer.to_string(modal.limit), else: ""),
        type: :text
      },
      %{label: "[ Apply Filter ]", key: :apply_button, type: :button},
      %{label: "[ Cancel ]", key: :cancel_button, type: :button}
    ]

    %{
      title: "FILTER & SORT DATA",
      mode: :filter,
      area: area,
      focused_field: modal.focused_field,
      fields: fields,
      status: modal.status,
      status_message: modal.status_message
    }
  end

  def render(%__MODULE__{mode: :export} = modal, area) do
    fields = [
      %{
        label: "Format",
        key: :format,
        value: Atom.to_string(modal.format),
        type: :select,
        options: Enum.map(@export_formats, &Atom.to_string/1)
      },
      %{label: "File Path", key: :file_path, value: modal.file_path, type: :text},
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
      status_message: modal.status_message
    }
  end

  defp fields_for_mode(:filter), do: @filter_fields
  defp fields_for_mode(:export), do: @export_fields

  defp field_key(:where), do: :where_clause
  defp field_key(:order_by), do: :order_by_clause
  defp field_key(:limit), do: :limit
  defp field_key(:file_path), do: :file_path
  defp field_key(k), do: k

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
