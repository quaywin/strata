defmodule Strata.UI.Components.Footer do
  @moduledoc """
  Footer component rendering bottom keybindings and mouse action bar
  dynamically from `Strata.UI.KeyRegistry`.
  """

  alias Strata.UI.KeyRegistry

  @doc """
  Renders footer bar containing relevant shortcuts for current focus state.
  """
  def render(app, area) do
    bindings = KeyRegistry.get_shortcuts(app)
    shortcuts_text = Enum.map_join(bindings, "  ", fn {key, label} -> "[#{key}] #{label}" end)
    status = Map.get(app, :status_message)

    text =
      if is_binary(status) and status != "" and status != "Ready" do
        "#{shortcuts_text}  │  #{status}"
      else
        shortcuts_text
      end

    %{
      area: area,
      text: text,
      shortcuts_text: shortcuts_text,
      status_message: status,
      keybindings: bindings
    }
  end

  @doc """
  Calculates clickable area coordinates for mouse interaction on footer buttons.
  """
  def clickable_actions(app, %{x: x_start, y: y_start, height: _h}) do
    bindings = KeyRegistry.get_shortcuts(app)

    # Renderer prepends 1 leading space before rendering shortcuts_text
    {actions, _offset} =
      Enum.reduce(bindings, {[], x_start + 1}, fn {key_name, label}, {acc, x_acc} ->
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

  defp parse_key_symbol("Tab"), do: :tab
  defp parse_key_symbol("Esc"), do: :esc
  defp parse_key_symbol("Enter"), do: :enter
  defp parse_key_symbol(<<ch::utf8>> = upper) when ch in ?A..?Z, do: String.to_atom(upper)
  defp parse_key_symbol(other), do: String.to_atom(String.downcase(other))
end
