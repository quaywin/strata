defmodule Strata.UI.Components.Footer do
  @moduledoc """
  Footer component rendering bottom keybindings and mouse action bar.
  """

  @doc """
  Renders footer bar containing relevant shortcuts for current focus state.
  """
  def render(app, area) do
    bindings = keybindings_for_app(app)
    text = Enum.map_join(bindings, "  ", fn {key, label} -> "[#{key}] #{label}" end)

    %{
      area: area,
      text: text,
      keybindings: bindings
    }
  end

  @doc """
  Calculates clickable area coordinates for mouse interaction on footer buttons.
  """
  def clickable_actions(app, %{x: x_start, y: y_start, height: _h}) do
    bindings = keybindings_for_app(app)

    {actions, _offset} =
      Enum.reduce(bindings, {[], x_start}, fn {key_name, label}, {acc, x_acc} ->
        str = "[#{key_name}] #{label}"
        len = String.length(str)

        btn_area = %{
          x: x_acc,
          y: y_start,
          width: len,
          height: 1
        }

        action = %{
          key: parse_key_symbol(key_name),
          label: str,
          area: btn_area
        }

        # spacing of 2 spaces between buttons
        {acc ++ [action], x_acc + len + 2}
      end)

    actions
  end

  defp keybindings_for_app(%{modals: [_top | _rest]}) do
    [
      {"Tab", "Next Field"},
      {"Enter", "Confirm"},
      {"Esc", "Cancel"}
    ]
  end

  defp keybindings_for_app(%{focus: :sidebar}) do
    [
      {"Ctrl+1/2", "Table/Query View"},
      {"Tab", "Focus Pane"},
      {"a", "Add Conn"},
      {"Enter", "Select/Open"},
      {"q", "Quit"}
    ]
  end

  defp keybindings_for_app(%{focus: :editor}) do
    [
      {"Ctrl+1/2", "Table/Query View"},
      {"Ctrl+Enter", "Run Query"},
      {"Tab", "Focus Pane"},
      {"Ctrl+N", "New Tab"},
      {"q", "Quit"}
    ]
  end

  defp keybindings_for_app(%{focus: :datagrid}) do
    [
      {"Ctrl+1/2", "Table/Query View"},
      {"Tab", "Focus Pane"},
      {"f", "Filter"},
      {"e", "Export"},
      {"n/p", "Next/Prev Page"},
      {"q", "Quit"}
    ]
  end

  defp keybindings_for_app(_app) do
    [
      {"Ctrl+1/2", "Table/Query View"},
      {"Tab", "Focus Pane"},
      {"Enter", "Action"},
      {"q", "Quit"}
    ]
  end

  defp parse_key_symbol("Tab"), do: :tab
  defp parse_key_symbol("Esc"), do: :esc
  defp parse_key_symbol("Enter"), do: :enter
  defp parse_key_symbol(other), do: String.to_atom(String.downcase(other))
end
