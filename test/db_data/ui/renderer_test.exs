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
      assert Map.has_key?(layout, :footer)
      assert Map.has_key?(layout, :header)

      # Footer should be at the bottom line
      assert layout.footer.y == 39
      assert layout.footer.height == 1
      assert layout.footer.width == 120

      # Sidebar should be on the left
      assert layout.sidebar.x == 0
      assert layout.sidebar.width > 0

      # Right panel (editor/datagrid) should be to the right of sidebar
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
      widgets = Renderer.render(app)

      assert is_list(widgets)
      assert length(widgets) == 6

      Enum.each(widgets, fn {widget, rect} ->
        assert is_struct(rect, ExRatatui.Layout.Rect)
        assert is_struct(widget)
      end)
    end

    test "renders modal overlay when app modal stack is not empty" do
      app =
        App.new(window_size: {120, 40})
        |> App.push_modal(%{type: :connection_modal, title: "Add Connection"})

      widgets = Renderer.render(app)

      assert is_list(widgets)
      # 6 main widgets + 2 modal widgets (Clear + Paragraph)
      assert length(widgets) == 8

      {modal_para, modal_rect} = List.last(widgets)
      assert is_struct(modal_rect, ExRatatui.Layout.Rect)
      assert String.contains?(modal_para.block.title, "CONNECTION PROFILE") or String.contains?(modal_para.block.title, "Add Connection")
    end

    test "renders and draws all modal types into CellSession successfully" do
      frame = %ExRatatui.Frame{width: 80, height: 24}
      session = ExRatatui.CellSession.new(80, 24)

      modals = [
        DBData.UI.Components.ConnectionModal.new(),
        DBData.UI.Components.CellDetailModal.new("sample content"),
        DBData.UI.Components.FilterExportModal.new(:filter),
        DBData.UI.Components.FilterExportModal.new(:export),
        %{type: :cell_detail_modal, title: "Cell Detail", content: "val"},
        %{type: :filter_modal, title: "Filter"},
        %{type: :export_modal, title: "Export"}
      ]

      Enum.each(modals, fn modal ->
        app = App.new(window_size: {80, 24}) |> App.push_modal(modal)
        rendered = App.render(app, frame)
        assert :ok == ExRatatui.CellSession.draw(session, rendered)
      end)
    end
  end
end
