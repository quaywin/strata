defmodule Strata.Formatter do
  @moduledoc """
  Formatting and sanitization helpers for DB cell values and TUI text strings.
  Ensures safe single-line display in table grids, automatic 16-byte UUID decoding,
  and rich full-content inspection in detail modals.
  """

  alias ExRatatui.Style
  alias ExRatatui.Text.Span

  @doc """
  Sanitizes any cell value into a safe single-line string for TUI grid display.
  Automatically converts 16-byte raw binaries to UUID strings.
  """
  def sanitize_cell(nil), do: "NULL"

  def sanitize_cell(<<_::128>> = uuid_bin) do
    format_uuid(uuid_bin)
  end

  def sanitize_cell(val) when is_binary(val) do
    if String.printable?(val) do
      if String.contains?(val, ["\r", "\n"]) do
        val
        |> String.replace("\r\n", " ↵ ")
        |> String.replace("\n", " ↵ ")
        |> String.replace("\r", " ↵ ")
      else
        val
      end
    else
      "<binary: #{byte_size(val)} bytes>"
    end
  end

  def sanitize_cell(val) when is_map(val) or is_list(val) or is_tuple(val) do
    case Jason.encode(val) do
      {:ok, json} ->
        if String.contains?(json, ["\r", "\n"]) do
          json |> String.replace("\r\n", " ") |> String.replace("\n", " ")
        else
          json
        end

      _ ->
        str = inspect(val)
        if String.contains?(str, ["\r", "\n"]), do: String.replace(str, ~r/\r?\n/, " "), else: str
    end
  end

  def sanitize_cell(val) do
    to_string(val)
  end

  @doc """
  Formats a cell value into a clean ExRatatui.Text.Span struct with plain text styling.
  """
  def format_cell_span(val, _col_w \\ nil) do
    %Span{content: sanitize_cell(val), style: %Style{fg: :white}}
  end



  @doc """
  Formats full cell value for detail inspection modal with pretty JSON formatting or Hex Dump for binary data.
  """
  def format_cell_detail(nil), do: "NULL"

  def format_cell_detail(<<_::128>> = uuid_bin) do
    "UUID: " <> format_uuid(uuid_bin)
  end

  def format_cell_detail(val) when is_binary(val) do
    if String.printable?(val) do
      case Jason.decode(val) do
        {:ok, decoded} ->
          Jason.encode!(decoded, pretty: true)

        _ ->
          val
      end
    else
      "Binary Data (#{byte_size(val)} bytes):\n\n" <> format_hex_dump(val)
    end
  end

  def format_cell_detail(val) when is_map(val) or is_list(val) do
    case Jason.encode(val, pretty: true) do
      {:ok, json} -> json
      _ -> inspect(val, pretty: true)
    end
  end

  def format_cell_detail(val), do: to_string(val)

  @doc """
  Converts a 16-byte raw binary into canonical UUID string format (8-4-4-4-12).
  Uses Erlang C NIF Base.encode16 for maximum speed.
  """
  def format_uuid(<<_::128>> = uuid_bin) do
    <<a::binary-size(8), b::binary-size(4), c::binary-size(4), d::binary-size(4), e::binary-size(12)>> =
      Base.encode16(uuid_bin, case: :lower)

    "#{a}-#{b}-#{c}-#{d}-#{e}"
  end

  defp format_hex_dump(binary) do
    binary
    |> :binary.bin_to_list()
    |> Enum.take(512)
    |> Enum.chunk_every(16)
    |> Enum.map_join("\n", fn chunk ->
      hex = Enum.map_join(chunk, " ", &String.pad_leading(Integer.to_string(&1, 16), 2, "0"))
      ascii = Enum.map_join(chunk, "", fn b -> if b >= 32 and b <= 126, do: <<b::utf8>>, else: "." end)
      "#{String.pad_trailing(hex, 48)}  |#{ascii}|"
    end)
  end
end
