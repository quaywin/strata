defmodule DBData.CLI do
  @moduledoc """
  CLI entrypoint for interactive Terminal User Interface (TUI).
  """

  alias DBData.UI.App
  alias DBData.UI.Renderer

  @doc """
  Main CLI entrypoint. Starts interactive TUI render loop.
  """
  def main(_args \\ []) do
    configure_terminal()

    app = App.new()

    render_frame(app)

    loop(app)
  end

  defp configure_terminal do
    IO.write("\e[?25l\e[2J\e[H")

    System.at_exit(fn _ ->
      IO.write("\e[?25h\e[2J\e[H")
    end)
  end

  defp render_frame(app) do
    {cols, rows} = get_terminal_size()
    app = %{app | window_size: {cols, rows}}

    rendered_text = Renderer.to_ansi(app)

    IO.write("\e[H" <> rendered_text)
  end

  defp loop(app) do
    case read_key() do
      :quit ->
        IO.write("\e[?25h\e[2J\e[H")
        IO.puts("Bye from dbdata! 🗄️")
        System.halt(0)

      key ->
        app = App.handle_key(app, key)
        render_frame(app)
        loop(app)
    end
  end

  defp read_key do
    case IO.read(:stdio, 1) do
      "q" -> :quit
      "\e" -> :esc
      "\n" -> :enter
      "\r" -> :enter
      "\t" -> :tab
      char when is_binary(char) -> char
      _ -> :unknown
    end
  end

  defp get_terminal_size do
    case :io.columns() do
      {:ok, cols} ->
        rows =
          case :io.rows() do
            {:ok, r} -> r
            _ -> 40
          end

        {cols, rows}

      _ ->
        {120, 40}
    end
  end
end
