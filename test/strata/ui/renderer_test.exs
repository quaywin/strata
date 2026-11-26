defmodule Strata.UI.RendererTest do
  use ExUnit.Case, async: true

  alias Strata.UI.App
  alias Strata.UI.Renderer

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

      assert String.contains?(modal_para.block.title, "CONNECTION PROFILE") or
               String.contains?(modal_para.block.title, "Add Connection")
    end

    test "renders and draws all modal types into CellSession successfully" do
      frame = %ExRatatui.Frame{width: 80, height: 24}
      session = ExRatatui.CellSession.new(80, 24)

      modals = [
        Strata.UI.Components.ConnectionModal.new(),
        Strata.UI.Components.CellDetailModal.new("sample content"),
        Strata.UI.Components.FilterExportModal.new(:filter),
        Strata.UI.Components.FilterExportModal.new(:export),
        Strata.UI.Components.SSHModal.new(),
        %{type: :cell_detail_modal, title: "Cell Detail", content: "val"},
        %{type: :filter_modal, title: "Filter"},
        %{type: :export_modal, title: "Export"},
        %{type: :ssh_modal, title: "SSH"}
      ]

      Enum.each(modals, fn modal ->
        app = App.new(window_size: {80, 24}) |> App.push_modal(modal)
        rendered = App.render(app, frame)
        assert :ok == ExRatatui.CellSession.draw(session, rendered)
      end)

      # Also verify highlighted SQL editor with multi-line scroll & cursor renders cleanly into CellSession
      long_sql = Enum.map_join(1..30, "\n", fn i -> "SELECT #{i} FROM users WHERE id = #{i};" end)

      query_app =
        App.new(window_size: {80, 24}, active_view: :query_view, focus: :editor)
        |> put_in([Access.key(:tabs), Access.at(0), :content], long_sql)
        |> put_in([Access.key(:tabs), Access.at(0), :cursor], {25, 7})

      assert :ok == ExRatatui.CellSession.draw(session, App.render(query_app, frame))

      conn_modal_area =
        Renderer.modal_area_for(
          App.push_modal(App.new(), Strata.UI.Components.ConnectionModal.new()),
          {120, 40}
        )

      assert conn_modal_area.width == 72
      assert conn_modal_area.height == 22

      # ActionsModal, Throbber loading state, staged edits/inserts/deletes, and inline TextInput render cleanly
      alias Strata.UI.Components.{ActionsModal, DataGrid}

      base_grid =
        DataGrid.new(["id", "name"], [[1, "Alice"], [2, "Bob"]],
          total_db_rows: 250,
          sort_by: {"name", :asc},
          mode: :selecting
        )
        |> DataGrid.stage_cell_edit(0, 1, "Alicia")
        |> DataGrid.insert_blank_row()
        |> DataGrid.toggle_delete_row(1)

      staged_app =
        App.new(
          window_size: {80, 24},
          active_view: :table_view,
          selected_table: "users",
          focus: :datagrid
        )
        |> Map.put(:datagrid_state, base_grid)

      assert :ok == ExRatatui.CellSession.draw(session, App.render(staged_app, frame))

      actions_app = App.push_modal(staged_app, ActionsModal.new(base_grid, :table_view))
      assert :ok == ExRatatui.CellSession.draw(session, App.render(actions_app, frame))

      editing_app = App.start_inline_edit(staged_app)
      assert :ok == ExRatatui.CellSession.draw(session, App.render(editing_app, frame))

      loading_grid = DataGrid.new(["Status"], [["Loading..."]], loading_more: true)

      loading_app =
        App.new(
          window_size: {80, 24},
          active_view: :table_view,
          selected_table: "users",
          datagrid_state: loading_grid,
          throbber_step: 2
        )

      assert :ok == ExRatatui.CellSession.draw(session, App.render(loading_app, frame))

      # Inline Filter Bar + Toggleable Right Inspector Drawer render together cleanly in CellSession
      filter_and_inspector_app =
        staged_app
        |> Map.put(:window_size, {120, 40})
        |> App.open_filter_bar()
        |> App.open_inspector()

      large_session = ExRatatui.CellSession.new(120, 40)
      large_frame = %ExRatatui.Frame{width: 120, height: 40}

      assert :ok ==
               ExRatatui.CellSession.draw(
                 large_session,
                 App.render(filter_and_inspector_app, large_frame)
               )

      raw_filter_app = App.handle_key(filter_and_inspector_app, {:ctrl, "r"})

      assert :ok ==
               ExRatatui.CellSession.draw(large_session, App.render(raw_filter_app, large_frame))

      dd_col_app = %{filter_and_inspector_app | filter_dropdown: :column, filter_dropdown_idx: 0}
      assert :ok == ExRatatui.CellSession.draw(large_session, App.render(dd_col_app, large_frame))

      dd_op_app = %{filter_and_inspector_app | filter_dropdown: :op, filter_dropdown_idx: 2}
      assert :ok == ExRatatui.CellSession.draw(large_session, App.render(dd_op_app, large_frame))

      sp_app = App.open_sort_picker(staged_app)
      assert :ok == ExRatatui.CellSession.draw(large_session, App.render(sp_app, large_frame))

      # Confirm delete connection modal renders compactly with rounded borders
      del_modal = %{
        type: :confirm_delete_connection,
        title: "CONFIRM DELETE",
        profile_id: "c1",
        content: "\n  Delete 'c1'?"
      }

      del_area = Renderer.modal_area_for(App.push_modal(App.new(), del_modal), {120, 40})
      assert {del_area.width, del_area.height} == {54, 9}

      assert :ok ==
               ExRatatui.CellSession.draw(
                 large_session,
                 App.render(App.push_modal(App.new(), del_modal), large_frame)
               )

      # JSON formatting + split fixed Inspector panes render cleanly in CellSession
      json_payload =
        ~s({"user":{"name":"Alice","age":30,"active":true,"note":null},"tags":["admin","db"]})

      {:ok, pretty_json} = Strata.Formatter.decode_json_pretty(json_payload)
      hl_lines = Strata.Formatter.highlight_json_lines(pretty_json, 32)
      assert length(hl_lines) > 4

      assert Enum.any?(hl_lines, fn %ExRatatui.Text.Line{spans: spans} ->
               Enum.any?(spans, &(&1.style.fg == :cyan))
             end)

      json_grid =
        DataGrid.new(["id", "payload"], [[1, json_payload]],
          mode: :selecting,
          selected_cell: {0, 1}
        )

      json_insp_app =
        App.new(window_size: {120, 40}, active_view: :table_view, datagrid_state: json_grid)
        |> App.open_inspector()

      assert :ok ==
               ExRatatui.CellSession.draw(large_session, App.render(json_insp_app, large_frame))

      # Inspector scrollbar reaches bottom cleanly when scrolled to max_value_scroll
      long_json = Jason.encode!(%{"items" => Enum.map(1..20, &%{"id" => &1})})

      long_grid =
        DataGrid.new(["id", "payload"], [[1, long_json]], mode: :selecting, selected_cell: {0, 1})

      bottom_app =
        App.new(window_size: {120, 30}, active_view: :table_view, datagrid_state: long_grid)
        |> App.open_inspector()

      %{inspector_area: ia} =
        Renderer.datagrid_areas(Renderer.layout({120, 30}, :table_view).datagrid, bottom_app)

      insp_data = Renderer.inspector_data(bottom_app, long_grid, long_grid.rows, ia)
      scrolled_bottom = %{bottom_app | inspector_value_scroll: insp_data.max_value_scroll}

      sb_widgets =
        Renderer.render(scrolled_bottom)
        |> Enum.filter(fn {w, _r} -> is_struct(w, ExRatatui.Widgets.Scrollbar) end)

      assert Enum.any?(sb_widgets, fn {sb, _r} -> sb.position == sb.content_length end)

      # Formatter.format_cell_span/2 and sanitize_cell_preview/2 truncate large payloads while keeping UUIDs intact
      huge_str = String.duplicate("a", 5_000)
      span = Strata.Formatter.format_cell_span(huge_str, 20)
      assert String.length(span.content) == 24

      assert Strata.Formatter.sanitize_cell_preview(<<1234::32, 0::96>>, 10) ==
               "000004d2-0000-0000-0000-000000000000"

      assert Strata.Formatter.sanitize_cell_preview("short", 20) == "short"
      assert String.length(Strata.Formatter.sanitize_cell_preview(%{"big" => huge_str}, 16)) == 20

      # Renderer.inspector_data/3 matches 4-arity output and draws cleanly
      insp_3 = Renderer.inspector_data(bottom_app, long_grid, ia)
      assert insp_3.value_lines == insp_data.value_lines
      assert insp_3.summary_lines == insp_data.summary_lines
      assert insp_3.total_rows == insp_data.total_rows
    end
  end
end
