defmodule Strata.UI.SelectionTest do
  use ExUnit.Case, async: true

  alias ExRatatui.Event.Mouse
  alias Strata.Clipboard
  alias Strata.UI.{App, Renderer, Selection}
  alias Strata.UI.Components.DataGrid

  describe "Drag-to-Select and auto-copy" do
    test "dragging text inside Inspector Data Field highlights and auto-copies on mouse up" do
      json_val = ~s({"username":"alice","role":"admin"})

      grid =
        DataGrid.new(["id", "meta"], [[1, json_val]], mode: :selecting, selected_cell: {0, 1})

      app =
        App.new(
          window_size: {120, 30},
          active_view: :table_view,
          focus: :datagrid,
          datagrid_state: grid
        )
        |> App.open_inspector()

      layout = Renderer.layout({120, 30}, :table_view)
      %{inspector_area: i_area} = Renderer.datagrid_areas(layout.datagrid, app)
      %{value_area: v_area} = Renderer.inspector_areas(i_area)

      # Drag across the rendered JSON value lines inside Inspector value pane
      start_x = v_area.x + 2
      start_y = v_area.y + 1
      end_x = v_area.x + v_area.width - 3
      end_y = v_area.y + 3

      {:noreply, s1, _} =
        App.handle_event(%Mouse{kind: "down", button: "left", x: start_x, y: start_y}, app)

      {:noreply, s2, _} =
        App.handle_event(%Mouse{kind: "drag", button: "left", x: end_x, y: end_y}, s1)

      assert s2.text_selection == {{start_x, start_y}, {end_x, end_y}}
      assert s2.selection_screen != nil

      # Verify render draws cyan highlight overlay and passes CellSession draw cleanly
      widgets = Renderer.render(s2)

      assert Enum.any?(widgets, fn {w, _r} ->
               is_struct(w, ExRatatui.Widgets.Paragraph) and is_nil(w.block) and
                 match?(
                   [
                     %ExRatatui.Text.Line{
                       spans: [%ExRatatui.Text.Span{style: %ExRatatui.Style{bg: :cyan}} | _]
                     }
                   ],
                   w.text
                 )
             end)

      session = ExRatatui.CellSession.new(120, 30)
      assert :ok == ExRatatui.CellSession.draw(session, widgets)
      ExRatatui.CellSession.close(session)

      # Mouse up auto-copies the selected JSON text without needing Shift or 'c'
      {:noreply, s3, _} =
        App.handle_event(%Mouse{kind: "up", button: "left", x: end_x, y: end_y}, s2)

      assert s3.text_selection == nil
      assert s3.selection_screen == nil
      assert s3.status_message =~ "Copied selection"

      {:ok, copied} = Clipboard.paste()
      assert copied =~ "username" or copied =~ "alice" or copied =~ "role"
      # Never bleeds into Grid/Sidebar borders outside Inspector
      refute copied =~ "│"
      refute copied =~ "CONNECTIONS"
    end

    test "dragging inside SQL Editor excludes line-number gutter when starting in code area" do
      app =
        App.new(window_size: {120, 30}, active_view: :query_view, focus: :editor)
        |> put_in(
          [Access.key(:tabs), Access.at(0), :content],
          "SELECT * FROM users;\nSELECT * FROM orders;"
        )

      layout = Renderer.layout({120, 30}, :query_view)
      ed = layout.editor
      # Body starts at ed.y + 1 (tabs row), border top at ed.y + 1, first code char at ed.x + 7
      start_x = ed.x + 7
      start_y = ed.y + 2
      end_x = ed.x + 30
      end_y = ed.y + 3

      {:noreply, s1, _} =
        App.handle_event(%Mouse{kind: "down", button: "left", x: start_x, y: start_y}, app)

      {:noreply, s2, _} =
        App.handle_event(%Mouse{kind: "drag", button: "left", x: end_x, y: end_y}, s1)

      {:noreply, _s3, _} =
        App.handle_event(%Mouse{kind: "up", button: "left", x: end_x, y: end_y}, s2)

      {:ok, copied} = Clipboard.paste()
      assert copied =~ "SELECT * FROM users;"
      assert copied =~ "SELECT * FROM orders;"
      refute copied =~ "│"
    end

    test "reverse drag (bottom-right to top-left) normalizes inclusive selection spans and matches highlighted WYSIWYG region on release" do
      bounds = %{min_x: 10, max_x: 20, min_y: 2, max_y: 8}
      spans = Selection.selection_spans({18, 5}, {12, 3}, bounds)
      assert spans == [{3, 12, 20}, {4, 10, 20}, {5, 10, 18}]

      # Single-line inclusive selection 10..14 selects exact 5 cols 10..14
      single = Selection.selection_spans({10, 3}, {14, 3}, bounds)
      assert single == [{3, 10, 14}]

      # Mouse up uses exact highlighted drag endpoint (WYSIWYG) even if up slightly shifts
      app =
        App.new(window_size: {120, 30}, active_view: :query_view, focus: :editor)
        |> put_in([Access.key(:tabs), Access.at(0), :content], "SELECT id FROM users;")

      ed = Renderer.layout({120, 30}, :query_view).editor

      {:noreply, s1, _} =
        App.handle_event(%Mouse{kind: "down", button: "left", x: ed.x + 7, y: ed.y + 2}, app)

      {:noreply, s2, _} =
        App.handle_event(%Mouse{kind: "drag", button: "left", x: ed.x + 12, y: ed.y + 2}, s1)

      # Even if mouse_up reports +1 col jitter (x = ed.x + 13), copied text matches exact dragged highlight "SELECT"
      {:noreply, _s3, _} =
        App.handle_event(%Mouse{kind: "up", button: "left", x: ed.x + 13, y: ed.y + 2}, s2)

      assert {:ok, "SELECT"} = Clipboard.paste()
    end

    test "wide characters (emoji & CJK) align 1:1 in overlays and copy without bogus spaces" do
      grid =
        DataGrid.new(
          ["id", "note", "meta"],
          [
            [1, "日本語テスト", ~s({"tag":"🔥hot"})]
          ],
          mode: :selecting,
          selected_cell: {0, 2}
        )

      sidebar_nodes = [
        %{
          id: "conn_1",
          label: "🐘 prod-db",
          type: :connection,
          expanded?: true,
          children: [%{id: "t1", label: "users", type: :table, expanded?: false, children: []}]
        }
      ]

      app =
        App.new(
          window_size: {120, 30},
          active_view: :table_view,
          focus: :datagrid,
          datagrid_state: grid,
          sidebar_nodes: sidebar_nodes,
          selected_tree_node_id: "t1"
        )
        |> App.open_inspector()

      layout = Renderer.layout({120, 30}, :table_view)
      areas = Renderer.datagrid_areas(layout.datagrid, app)
      insp = Renderer.inspector_areas(areas.inspector_area)
      screen = Selection.capture_screen(app)

      assert_zero_symbol_mismatch = fn ax, ay, cx, cy ->
        bounds = Selection.bounds_for_anchor(app, {ax, ay})

        app_sel = %{
          app
          | text_selection: {{ax, ay}, {cx, cy}},
            selection_screen: screen,
            selection_bounds: bounds
        }

        base_cells = render_cell_map(app, 120, 30)
        sel_cells = render_cell_map(app_sel, 120, 30)

        mismatches =
          for {{x, y}, c1} <- base_cells,
              c2 = Map.fetch!(sel_cells, {x, y}),
              c1.symbol != c2.symbol do
            {y, x, c1.symbol, c2.symbol}
          end

        assert mismatches == []
        Selection.extract_text(screen, {ax, ay}, {cx, cy}, bounds)
      end

      grid_text =
        assert_zero_symbol_mismatch.(
          areas.grid_area.x + 1,
          areas.grid_area.y + 2,
          areas.grid_area.x + 50,
          areas.grid_area.y + 2
        )

      assert grid_text =~ "日本語"
      assert grid_text =~ ~s({"tag":"🔥hot"})
      refute grid_text =~ "日 本"

      insp_text =
        assert_zero_symbol_mismatch.(
          insp.value_area.x + 1,
          insp.value_area.y + 1,
          insp.value_area.x + 30,
          insp.value_area.y + 4
        )

      assert insp_text =~ ~s("tag": "🔥hot")

      sb_text =
        assert_zero_symbol_mismatch.(
          layout.sidebar.x + 1,
          layout.sidebar.y + 1,
          layout.sidebar.x + 25,
          layout.sidebar.y + 2
        )

      assert sb_text =~ "🐘 prod-db"
      refute sb_text =~ "🐘  prod-db"
    end

    test "wide-character boundary snapping adjusts trailing left half and leading right half cleanly" do
      grid = DataGrid.new(["note"], [["🔥hot"]], mode: :selecting, selected_cell: {0, 0})

      app =
        App.new(
          window_size: {80, 20},
          active_view: :table_view,
          focus: :datagrid,
          datagrid_state: grid
        )
        |> App.open_inspector()

      layout = Renderer.layout({80, 20}, :table_view)
      areas = Renderer.datagrid_areas(layout.datagrid, app)
      insp = Renderer.inspector_areas(areas.inspector_area)
      v_area = insp.value_area

      screen = Selection.capture_screen(app)
      row_y = v_area.y + 1
      bounds = Selection.bounds_for_anchor(app, {v_area.x + 1, row_y})

      {fire_x, _} =
        screen.rows[row_y]
        |> Enum.find(fn {_col, sym} -> sym == "🔥" end)

      # Starting drag on the trailing half (fire_x + 1) snaps left to fire_x and aligns "hot"
      assert Selection.extract_text(screen, {fire_x + 1, row_y}, {fire_x + 4, row_y}, bounds) ==
               "🔥hot"

      # Ending drag on the leading half (fire_x) expands right to fire_x + 1 so "🔥" renders & copies intact
      assert Selection.extract_text(screen, {v_area.x + 1, row_y}, {fire_x, row_y}, bounds) == "🔥"

      [{overlay_w, overlay_rect}] =
        Selection.render_overlays(screen, {v_area.x + 1, row_y}, {fire_x, row_y}, bounds)

      assert overlay_rect.width == fire_x + 1 - (v_area.x + 1) + 1
      assert overlay_w.style.bg == :cyan
    end

    test "deferred click prevents premature scroll/collapse during drag, while normal click and right-click behave properly" do
      # 1. Scrolled SQL Editor: drag on top visible row copies scrolled line, never jumps or copies "█"
      sql_lines = Enum.map_join(1..15, "\n", &"SELECT col_#{&1} FROM t_#{&1};")

      scrolled_app =
        App.new(window_size: {120, 30}, active_view: :query_view, focus: :editor)
        |> put_in([Access.key(:tabs), Access.at(0), :content], sql_lines)
        |> put_in([Access.key(:tabs), Access.at(0), :cursor], {14, 5})

      ed = Renderer.layout({120, 30}, :query_view).editor
      ax = ed.x + 7
      ay = ed.y + 2
      cx = ed.x + 30
      cy = ed.y + 2

      {:noreply, s1, _} =
        App.handle_event(%Mouse{kind: "down", button: "left", x: ax, y: ay}, scrolled_app)

      {:noreply, s2, _} = App.handle_event(%Mouse{kind: "drag", button: "left", x: cx, y: cy}, s1)
      {:noreply, s3, _} = App.handle_event(%Mouse{kind: "up", button: "left", x: cx, y: cy}, s2)

      assert {:ok, copied_sql} = Clipboard.paste()
      assert copied_sql =~ "SELECT col_7 FROM t_7;"
      refute copied_sql =~ "col_1 "
      refute copied_sql =~ "█"
      assert hd(s3.tabs).cursor == {14, 5}

      # 2. Sidebar: dragging across an expanded connection copies label without collapsing it
      sidebar_nodes = [
        %{
          id: "conn_1",
          label: "🐘 prod-db",
          type: :connection,
          expanded?: true,
          children: [%{id: "t1", label: "users", type: :table, expanded?: false, children: []}]
        }
      ]

      sb_app =
        App.new(
          window_size: {120, 30},
          active_view: :table_view,
          focus: :sidebar,
          sidebar_nodes: sidebar_nodes,
          selected_tree_node_id: "conn_1"
        )

      sb = Renderer.layout({120, 30}, :table_view).sidebar

      {:noreply, sb1, _} =
        App.handle_event(%Mouse{kind: "down", button: "left", x: sb.x + 2, y: sb.y + 1}, sb_app)

      {:noreply, sb2, _} =
        App.handle_event(%Mouse{kind: "drag", button: "left", x: sb.x + 20, y: sb.y + 1}, sb1)

      {:noreply, sb3, _} =
        App.handle_event(%Mouse{kind: "up", button: "left", x: sb.x + 20, y: sb.y + 1}, sb2)

      assert hd(sb3.sidebar_nodes).expanded? == true
      assert {:ok, sb_copied} = Clipboard.paste()
      assert sb_copied =~ "prod-db"

      # 3. Normal click (down + up without drag) toggles sidebar connection & selects DataGrid cell
      {:noreply, c1, _} =
        App.handle_event(%Mouse{kind: "down", button: "left", x: sb.x + 2, y: sb.y + 1}, sb_app)

      {:noreply, c2, _} =
        App.handle_event(%Mouse{kind: "up", button: "left", x: sb.x + 2, y: sb.y + 1}, c1)

      assert hd(c2.sidebar_nodes).expanded? == false

      grid =
        DataGrid.new(["id", "name"], [[1, "Alice"], [2, "Bob"]],
          mode: :browsing,
          selected_cell: {0, 0}
        )

      grid_app =
        App.new(
          window_size: {120, 30},
          active_view: :table_view,
          focus: :datagrid,
          datagrid_state: grid
        )

      g_area =
        Renderer.datagrid_areas(Renderer.layout({120, 30}, :table_view).datagrid, grid_app).grid_area

      {:noreply, gc1, _} =
        App.handle_event(
          %Mouse{kind: "down", button: "left", x: g_area.x + 2, y: g_area.y + 3},
          grid_app
        )

      assert gc1.datagrid_state.selected_cell == {0, 0}

      {:noreply, gc2, _} =
        App.handle_event(
          %Mouse{kind: "up", button: "left", x: g_area.x + 2, y: g_area.y + 3},
          gc1
        )

      assert gc2.datagrid_state.selected_cell == {1, 0}

      # 4. Right-click down + drag + up never initiates text selection
      {:noreply, r1, _} =
        App.handle_event(
          %Mouse{kind: "down", button: "right", x: g_area.x + 2, y: g_area.y + 2},
          grid_app
        )

      {:noreply, r2, _} =
        App.handle_event(
          %Mouse{kind: "drag", button: "right", x: g_area.x + 8, y: g_area.y + 2},
          r1
        )

      {:noreply, r3, _} =
        App.handle_event(
          %Mouse{kind: "up", button: "right", x: g_area.x + 8, y: g_area.y + 2},
          r2
        )

      assert r1.drag_anchor == nil
      assert r2.text_selection == nil
      assert r3.text_selection == nil
    end

    test "SQL Editor bounds exclude top border, shrink back to 1 char, and Resize clears selection" do
      app =
        App.new(window_size: {120, 30}, active_view: :query_view, focus: :editor)
        |> put_in([Access.key(:tabs), Access.at(0), :content], "SELECT id FROM users;")

      ed = Renderer.layout({120, 30}, :query_view).editor
      bounds = Selection.bounds_for_anchor(app, {ed.x + 7, ed.y + 2})
      assert bounds.min_y == ed.y + 2
      assert bounds.min_x == ed.x + 7

      # Drag out then back to anchor shrinks selection to 1 char and copies "S"
      anchor = {ed.x + 7, ed.y + 2}

      {:noreply, s1, _} =
        App.handle_event(%Mouse{kind: "down", button: "left", x: ed.x + 7, y: ed.y + 2}, app)

      {:noreply, s2, _} =
        App.handle_event(%Mouse{kind: "drag", button: "left", x: ed.x + 12, y: ed.y + 2}, s1)

      {:noreply, s3, _} =
        App.handle_event(%Mouse{kind: "drag", button: "left", x: ed.x + 7, y: ed.y + 2}, s2)

      assert s3.text_selection == {anchor, anchor}

      # Resize updates window_size and clears active selection state
      {:noreply, resized} = App.handle_event(%ExRatatui.Event.Resize{width: 100, height: 25}, s3)
      assert resized.window_size == {100, 25}
      assert resized.drag_anchor == nil
      assert resized.text_selection == nil
      assert resized.selection_screen == nil
      assert resized.selection_bounds == nil

      # Releasing after shrinking copies single character "S"
      {:noreply, _s4, _} =
        App.handle_event(%Mouse{kind: "up", button: "left", x: ed.x + 7, y: ed.y + 2}, s3)

      assert {:ok, "S"} = Clipboard.paste()
    end
  end

  defp render_cell_map(app, width, height) do
    session = ExRatatui.CellSession.new(width, height)

    try do
      :ok = ExRatatui.CellSession.draw(session, Renderer.render(app))
      ExRatatui.CellSession.take_cells(session).cells |> Map.new(&{{&1.col, &1.row}, &1})
    after
      _ = ExRatatui.CellSession.close(session)
    end
  end
end
