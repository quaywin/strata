defmodule Strata.UI.Components.FooterTest do
  use ExUnit.Case, async: true

  alias Strata.UI.App
  alias Strata.UI.Components.Footer

  describe "Footer rendering" do
    test "renders footer bar keybindings for main focus panes" do
      app_sidebar = App.new(focus: :sidebar)
      rendered = Footer.render(app_sidebar, %{x: 0, y: 39, width: 120, height: 1})

      assert rendered.area == %{x: 0, y: 39, width: 120, height: 1}
      assert is_binary(rendered.text)
      assert rendered.text =~ "Table/Query View"
      assert rendered.text =~ "Add Conn"
    end

    test "renders modal keybindings when modal active" do
      app_modal = App.new() |> App.push_modal(%{type: :connection_modal, title: "New Connection"})
      rendered = Footer.render(app_modal, %{x: 0, y: 39, width: 120, height: 1})

      assert rendered.text =~ "Esc" or rendered.text =~ "Cancel"
    end

    test "returns clickable action items with coordinates" do
      app = App.new()
      area = %{x: 0, y: 39, width: 120, height: 1}

      actions = Footer.clickable_actions(app, area)
      assert is_list(actions)
      assert length(actions) > 0

      first_action = List.first(actions)
      assert Map.has_key?(first_action, :label)
      assert Map.has_key?(first_action, :key)
      assert Map.has_key?(first_action, :area)
    end
  end
end
