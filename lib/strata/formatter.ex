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

  def sanitize_cell(val) when is_binary(val) do
    cond do
      String.printable?(val) ->
        if String.contains?(val, ["\r", "\n"]) do
          val
          |> String.replace("\r\n", " ↵ ")
          |> String.replace("\n", " ↵ ")
          |> String.replace("\r", " ↵ ")
        else
          val
        end

      byte_size(val) == 16 ->
        format_uuid(val)

      true ->
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
  Formats a cell value into a clean ExRatatui.Text.Span struct with plain text styling,
  truncating oversized strings/JSON early according to `col_w`.
  """
  def format_cell_span(val, col_w \\ nil) do
    %Span{content: sanitize_cell_preview(val, col_w), style: %Style{fg: :white}}
  end

  @doc """
  Sanitizes a cell value into a safe single-line preview bounded to `max_chars + 4`
  characters when `max_chars` is provided, avoiding full scans of large TEXT/JSON blobs.
  """
  def sanitize_cell_preview(val, max_chars) when is_integer(max_chars) and max_chars > 0 do
    cond do
      is_nil(val) ->
        "NULL"

      is_binary(val) ->
        if byte_size(val) == 16 and not String.printable?(val) do
          format_uuid(val)
        else
          limit = max_chars + 4

          if String.printable?(val, limit) do
            head = if byte_size(val) > limit, do: String.slice(val, 0, limit), else: val

            if String.contains?(head, ["\r", "\n"]) do
              head
              |> String.replace("\r\n", " ↵ ")
              |> String.replace("\n", " ↵ ")
              |> String.replace("\r", " ↵ ")
            else
              head
            end
          else
            "<binary: #{byte_size(val)} bytes>"
          end
        end

      is_map(val) or is_list(val) or is_tuple(val) ->
        Strata.UI.Cache.fetch(:cell_json_preview, {val, max_chars}, 512, fn ->
          limit = max_chars + 4
          str = sanitize_cell(val)
          if String.length(str) > limit, do: String.slice(str, 0, limit), else: str
        end)

      true ->
        limit = max_chars + 4
        str = to_string(val)
        if String.length(str) > limit, do: String.slice(str, 0, limit), else: str
    end
  end

  def sanitize_cell_preview(val, _max_chars), do: sanitize_cell(val)

  @doc """
  Decodes `value` into `{:ok, pretty_json_string}` if it is a map/list, valid JSON string,
  or double-encoded JSON string; otherwise returns `:error`.
  """
  @spec decode_json_pretty(term()) :: {:ok, String.t()} | :error
  def decode_json_pretty(val) when is_map(val) or is_list(val) do
    case Jason.encode(val, pretty: true) do
      {:ok, json} -> {:ok, json}
      _ -> :error
    end
  end

  def decode_json_pretty(val) when is_binary(val) do
    trimmed = String.trim(val)

    cond do
      (String.starts_with?(trimmed, "{") and String.ends_with?(trimmed, "}")) or
          (String.starts_with?(trimmed, "[") and String.ends_with?(trimmed, "]")) ->
        case Jason.decode(trimmed) do
          {:ok, parsed} when is_map(parsed) or is_list(parsed) ->
            {:ok, Jason.encode!(parsed, pretty: true)}

          _ ->
            :error
        end

      String.starts_with?(trimmed, "\"") and String.ends_with?(trimmed, "\"") ->
        case Jason.decode(trimmed) do
          {:ok, inner} when is_binary(inner) -> decode_json_pretty(inner)
          _ -> :error
        end

      true ->
        :error
    end
  end

  def decode_json_pretty(_), do: :error

  @doc """
  Tokenizes a pretty-printed JSON string into syntax-highlighted `ExRatatui.Text.Line` structs,
  optionally wrapping lines to `max_width`.
  """
  @spec highlight_json_lines(String.t(), pos_integer() | nil) :: [ExRatatui.Text.Line.t()]
  def highlight_json_lines(json_str, max_width \\ nil) when is_binary(json_str) do
    json_str
    |> String.split("\n")
    |> Enum.flat_map(fn line_str ->
      spans = tokenize_json_line(line_str)

      if is_integer(max_width) and max_width > 0 do
        wrap_spans(spans, max_width)
      else
        [ExRatatui.Text.Line.new(spans)]
      end
    end)
  end

  @doc """
  Wraps plain text into `ExRatatui.Text.Line` structs fitting within `max_width`.
  """
  @spec wrap_text_lines(String.t(), pos_integer(), ExRatatui.Style.t()) :: [
          ExRatatui.Text.Line.t()
        ]
  def wrap_text_lines(text, max_width, style \\ %Style{fg: :white}) when is_binary(text) do
    w = max(4, max_width)

    text
    |> String.split("\n")
    |> Enum.flat_map(fn ln ->
      if ln == "" do
        [ExRatatui.Text.Line.new([%Span{content: "", style: style}])]
      else
        wrap_string(ln, w)
        |> Enum.map(fn seg -> ExRatatui.Text.Line.new([%Span{content: seg, style: style}]) end)
      end
    end)
  end

  defp tokenize_json_line(line_str) do
    regex =
      ~r/(\"(?:\\.|[^\"\\])*\"\s*:|\"(?:\\.|[^\"\\])*\"|-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?|\btrue\b|\bfalse\b|\bnull\b|[{}\[\],:]|\s+|[^\s{}\[\],:\"]+)/

    Regex.scan(regex, line_str)
    |> Enum.map(fn [tok | _] ->
      style =
        cond do
          String.match?(tok, ~r/^\s+$/) ->
            %Style{}

          String.match?(tok, ~r/^\"(?:\\.|[^\"\\])*\"\s*:$/) ->
            # Split key and trailing colon cleanly so colon stays subtle
            nil

          String.starts_with?(tok, "\"") ->
            %Style{fg: :green}

          tok in ["true", "false"] ->
            %Style{fg: :yellow, modifiers: [:bold]}

          tok == "null" ->
            %Style{fg: :dark_gray}

          String.match?(tok, ~r/^-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?$/) ->
            %Style{fg: :magenta}

          tok in ["{", "}", "[", "]", ",", ":"] ->
            %Style{fg: :white}

          true ->
            %Style{fg: :white}
        end

      if style == nil do
        [_, key_part, sep_part] = Regex.run(~r/^(\"(?:\\.|[^\"\\])*\")(\s*:)$/, tok)

        [
          %Span{content: key_part, style: %Style{fg: :cyan, modifiers: [:bold]}},
          %Span{content: sep_part, style: %Style{fg: :white}}
        ]
      else
        [%Span{content: tok, style: style}]
      end
    end)
    |> List.flatten()
    |> case do
      [] -> [%Span{content: "", style: %Style{}}]
      spans -> spans
    end
  end

  defp wrap_spans(spans, max_width) do
    w = max(4, max_width)

    {rev_lines, rev_cur, _cur_len} =
      Enum.reduce(spans, {[], [], 0}, fn %Span{content: txt, style: st}, {acc_lines, cur, len} ->
        len_txt = String.length(txt)

        cond do
          len + len_txt <= w ->
            {acc_lines, [%Span{content: txt, style: st} | cur], len + len_txt}

          len_txt <= w ->
            new_lines =
              if cur == [],
                do: acc_lines,
                else: [ExRatatui.Text.Line.new(Enum.reverse(cur)) | acc_lines]

            {new_lines, [%Span{content: txt, style: st}], len_txt}

          true ->
            chunks = wrap_string(txt, w)
            first = hd(chunks)
            rest = tl(chunks)

            base_lines =
              if cur == [],
                do: acc_lines,
                else: [ExRatatui.Text.Line.new(Enum.reverse(cur)) | acc_lines]

            if rest == [] do
              {base_lines, [%Span{content: first, style: st}], String.length(first)}
            else
              {mid, [last]} = Enum.split(rest, -1)

              rev_added =
                Enum.reduce([first | mid], base_lines, fn s, acc ->
                  [ExRatatui.Text.Line.new([%Span{content: s, style: st}]) | acc]
                end)

              {rev_added, [%Span{content: last, style: st}], String.length(last)}
            end
        end
      end)

    rev_final =
      if rev_cur != [] or rev_lines == [] do
        [ExRatatui.Text.Line.new(Enum.reverse(rev_cur)) | rev_lines]
      else
        rev_lines
      end

    Enum.reverse(rev_final)
  end

  defp wrap_string(str, width) do
    str
    |> String.graphemes()
    |> Enum.chunk_every(width)
    |> Enum.map(&Enum.join/1)
  end

  @doc """
  Formats full cell value for detail inspection modal with pretty JSON formatting or Hex Dump for binary data.
  """
  def format_cell_detail(nil), do: "NULL"

  def format_cell_detail(val) when is_binary(val) do
    cond do
      String.printable?(val) ->
        case Jason.decode(val) do
          {:ok, decoded} ->
            Jason.encode!(decoded, pretty: true)

          _ ->
            val
        end

      byte_size(val) == 16 ->
        "UUID: " <> format_uuid(val)

      true ->
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
    <<a::binary-size(8), b::binary-size(4), c::binary-size(4), d::binary-size(4),
      e::binary-size(12)>> =
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

      ascii =
        Enum.map_join(chunk, "", fn b -> if b >= 32 and b <= 126, do: <<b::utf8>>, else: "." end)

      "#{String.pad_trailing(hex, 48)}  |#{ascii}|"
    end)
  end
end
