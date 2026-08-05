defmodule DBData.Formatter do
  @moduledoc """
  Formatting and sanitization helpers for DB cell values and TUI text strings.
  Ensures safe single-line display in table grids, automatic 16-byte UUID decoding,
  and rich full-content inspection in detail modals.
  """

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
      val
      |> String.replace("\r\n", " ↵ ")
      |> String.replace("\n", " ↵ ")
      |> String.replace("\r", " ↵ ")
    else
      "<binary: #{byte_size(val)} bytes>"
    end
  end

  def sanitize_cell(val) when is_map(val) or is_list(val) or is_tuple(val) do
    case Jason.encode(val) do
      {:ok, json} ->
        json |> String.replace("\r\n", " ") |> String.replace("\n", " ")

      _ ->
        inspect(val) |> String.replace("\r\n", " ") |> String.replace("\n", " ")
    end
  end

  def sanitize_cell(val) do
    to_string(val) |> String.replace("\r\n", " ") |> String.replace("\n", " ")
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
  """
  def format_uuid(<<a::32, b::16, c::16, d::16, e::48>>) do
    a_str = Integer.to_string(a, 16) |> String.downcase() |> String.pad_leading(8, "0")
    b_str = Integer.to_string(b, 16) |> String.downcase() |> String.pad_leading(4, "0")
    c_str = Integer.to_string(c, 16) |> String.downcase() |> String.pad_leading(4, "0")
    d_str = Integer.to_string(d, 16) |> String.downcase() |> String.pad_leading(4, "0")
    e_str = Integer.to_string(e, 16) |> String.downcase() |> String.pad_leading(12, "0")

    "#{a_str}-#{b_str}-#{c_str}-#{d_str}-#{e_str}"
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
