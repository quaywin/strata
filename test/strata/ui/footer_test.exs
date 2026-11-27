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
      assert rendered.text =~ "New SQL Tab"
      assert rendered.text =~ "Add Conn"

      app_editor = App.new(focus: :editor)
      rendered_ed = Footer.render(app_editor, %{x: 0, y: 39, width: 120, height: 1})
      assert rendered_ed.text =~ "Ctrl+Enter"
      assert rendered_ed.text =~ "Ctrl+←/→"
      assert rendered_ed.text =~ "Ctrl+W"

      app_with_status = %{app_sidebar | status_message: "[Cache] Loaded users (50 rows)"}
      rendered_status = Footer.render(app_with_status, %{x: 0, y: 39, width: 120, height: 1})
      assert rendered_status.text =~ "[Cache] Loaded users (50 rows)"
    end

    test "renders modal keybindings when modal active" do
      app_modal =
        App.new() |> App.push_modal(Strata.UI.Components.ConnectionModal.new())

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

      # Uppercase shortcut keys retain case so clicking 'E' (Export) dispatches accurately
      assert Enum.any?(actions, &(&1.key == :a))

      grid_app =
        App.new(
          focus: :datagrid,
          active_view: :table_view,
          datagrid_state: Strata.UI.Components.DataGrid.new(["id"], [[1]])
        )

      grid_actions = Footer.clickable_actions(grid_app, area)
      assert Enum.any?(grid_actions, &(&1.key == :E))
      assert Enum.any?(grid_actions, &(&1.key == :"ctrl+g"))
    end
  end
end
