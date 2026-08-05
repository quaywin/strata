defmodule DBData.UI.RendererTest do
  use ExUnit.Case, async: true

  alias DBData.UI.App
  alias DBData.UI.Renderer

  describe "Layout partitioning" do
    test "partitions window size into grid areas" do
      window_size = {120, 40}
      layout = Renderer.layout(window_size)

      assert is_map(layout)
      assert Map.has_key?(layout, :sidebar)
      assert Map.has_key?(layout, :editor)
      assert Map.has_key?(layout, :datagrid)
      assert Map.has_key?(layout, :log)
      assert Map.has_key?(layout, :footer)
      assert Map.has_key?(layout, :header)

      # Footer should be at the bottom line
      assert layout.footer.y == 39
      assert layout.footer.height == 1
      assert layout.footer.width == 120

      # Sidebar should be on the left
      assert layout.sidebar.x == 0
      assert layout.sidebar.width > 0

      # Right panel (editor/datagrid/log) should be to the right of sidebar
      assert layout.editor.x >= layout.sidebar.width
    end

    test "calculates centered modal overlay box" do
      window_size = {120, 40}
      modal_area = Renderer.modal_layout(window_size, {60, 20})

      assert modal_area.width == 60
      assert modal_area.height == 20
      assert modal_area.x == 30
      assert modal_area.y == 10
    end
  end

  describe "Full UI rendering" do
    test "renders complete tree for app state without modal" do
      app = App.new(window_size: {120, 40})
      tree = Renderer.render(app)

      assert is_map(tree)
      assert tree.window_size == {120, 40}
      assert tree.active_focus == :sidebar
      assert is_map(tree.chunks.sidebar)
      assert is_map(tree.chunks.footer)
      assert tree.modal == nil
    end

    test "renders modal overlay when app modal stack is not empty" do
      app =
        App.new(window_size: {120, 40})
        |> App.push_modal(%{type: :connection_modal, title: "Add Connection"})

      tree = Renderer.render(app)

      assert tree.modal != nil
      assert tree.modal.title == "Add Connection"
      assert tree.modal.area.width > 0
    end
  end
end
