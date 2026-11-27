defmodule Strata.UI.AIIntegrationTest do
  use ExUnit.Case, async: true

  alias Strata.AISettings
  alias Strata.UI.App
  alias Strata.UI.Components.ActionsModal
  alias Strata.UI.Components.AIChatPanel
  alias Strata.UI.Components.AISettingsModal
  alias Strata.UI.Components.SQLTabPickerModal
  alias Strata.UI.KeyRegistry
  alias Strata.UI.Renderer

  describe "AISettingsModal" do
    test "supports cycling provider, context scope, keep_conversation, model input, save, and test" do
      modal =
        AISettingsModal.new(
          settings: %AISettings{
            provider: :claude,
            model: "",
            context_scope: :focused_and_related,
            keep_conversation: true
          }
        )

      cycled = AISettingsModal.handle_key(modal, :right)
      assert cycled.provider == :codex

      m2 =
        cycled
        |> AISettingsModal.handle_key(:tab)
        |> AISettingsModal.handle_key("o")
        |> AISettingsModal.handle_key("3")
        |> AISettingsModal.handle_key(:tab)
        |> AISettingsModal.handle_key(:right)
        |> AISettingsModal.handle_key(:tab)
        |> AISettingsModal.handle_key(:space)

      settings = AISettingsModal.to_settings(m2)
      assert settings.provider == :codex
      assert settings.model == "o3"
      assert settings.context_scope == :focused_only
      assert settings.keep_conversation == false

      assert {:save, _} = AISettingsModal.handle_key(m2, {:ctrl, "s"})
      rendered = AISettingsModal.render(m2, %{x: 0, y: 0, width: 74, height: 18})
      assert rendered.title == "AI ASSISTANT SETTINGS"
      assert Enum.any?(rendered.fields, &(&1.key == :test_button))
    end
  end

  describe "AIChatPanel & Renderer layout" do
    test "places AI drawer next to Editor only (leaving DataGrid full width) and draws into CellSession" do
      layout = Renderer.layout({120, 40}, :query_view, ai_panel_open: true)
      assert is_map(layout.ai_panel)
      assert layout.ai_panel.x == layout.editor.x + layout.editor.width
      assert layout.ai_panel.y == layout.editor.y
      assert layout.ai_panel.height == layout.editor.height
      assert layout.datagrid.width == layout.editor.width + layout.ai_panel.width

      app =
        App.new(window_size: {120, 40}, ai_panel_open: true, focus: :ai_panel)
        |> put_in([Access.key(:tabs), Access.at(0), :ai_messages], [
          %{
            id: "m1",
            prompt: "top 5 users",
            sql: "SELECT * FROM users LIMIT 5;",
            is_read_only: true,
            explanation: "Top 5 users",
            error: nil,
            status: :done
          }
        ])
        |> put_in([Access.key(:tabs), Access.at(0), :ai_applied_msg_id], "m1")

      assert KeyRegistry.determine_context(app) == :ai_panel_input

      frame = %ExRatatui.Frame{width: 120, height: 40}
      session = ExRatatui.CellSession.new(120, 40)
      assert :ok == ExRatatui.CellSession.draw(session, App.render(app, frame))

      settings_app = App.open_ai_settings_modal(App.new(window_size: {120, 40}))
      assert [%AISettingsModal{}] = settings_app.modals
      assert :ok == ExRatatui.CellSession.draw(session, App.render(settings_app, frame))
    end
  end

  describe "App + Right AI Chat Panel integration" do
    test "opens AI settings from ActionsModal" do
      app = App.new(focus: :sidebar)
      app = App.open_actions_modal(app)
      assert [%ActionsModal{items: items}] = app.modals
      assert Enum.any?(items, &(&1.id == :ai_settings))
    end

    test "toggles Right AI panel via bottom SQL editor [AI] click and tracks multi-turn SQL results" do
      app = App.new(window_size: {120, 40}) |> App.open_tab(name: "Query 1", content: "")
      tab_id = app.active_tab_id

      layout = Renderer.layout_for(app)
      tb = Renderer.tab_bar_layout(app, layout.tabs)
      refute Map.has_key?(tb, :ai_sql_rect)

      ai_rect = Renderer.editor_ai_button_rect(app, layout.editor)
      run_rect = Renderer.editor_run_button_rect(app, layout.editor)
      assert is_map(ai_rect)
      assert is_map(run_rect)
      assert ai_rect.y == layout.editor.y + layout.editor.height - 1
      assert run_rect.y == ai_rect.y
      assert run_rect.x + run_rect.width < ai_rect.x
      assert ai_rect.width == String.length(" [AI] ")
      assert run_rect.width == String.length(" [Run] ")
      refute Enum.any?(tb.tabs, &String.contains?(&1.label, "*"))

      # Clicking [Run] executes SQL query (empty query warning when blank)
      ran_empty = App.handle_mouse(app, {:click, run_rect.x + 1, run_rect.y})
      assert ran_empty.status_message =~ "empty SQL query"

      # Clicking [AI] at bottom of SQL editor opens the Right AI Chat Panel and focuses input
      opened = App.handle_mouse(app, {:click, ai_rect.x + 1, ai_rect.y})
      assert opened.ai_panel_open == true
      assert opened.focus == :ai_panel
      assert opened.ai_panel_focus == :input

      # Typing includes 'q', '?', '1' and Shift+Enter inserts newline without submitting
      {:noreply, typed_nl} =
        App.handle_event(%ExRatatui.Event.Key{code: "enter", modifiers: ["shift"]}, opened)

      typed =
        opened
        |> App.handle_key("q")
        |> App.handle_key(:shift_enter)
        |> App.handle_key("1")
        |> App.handle_key("?")

      assert typed_nl.ai_input_text == "\n"
      assert typed.ai_input_text == "q\n1?"

      # Cycle focus includes :ai_panel
      assert App.cycle_focus(%{typed | focus: :datagrid}, :next).focus == :ai_panel

      # Simulate two completed AI turns
      req1 = make_ref()

      pending1 =
        typed
        |> update_in([Access.key(:tabs), Access.at(1), :ai_messages], fn msgs ->
          (msgs || []) ++
            [
              %{
                id: "m1",
                prompt: "list users",
                sql: nil,
                is_read_only: true,
                explanation: nil,
                error: nil,
                status: :running
              }
            ]
        end)
        |> Map.put(:ai_request, %{id: req1, pid: self(), tab_id: tab_id, msg_id: "m1"})

      # Regression check: :throbber_tick must not crash when datagrid_state is nil during AI request
      {:noreply, ticked} = App.handle_info(:throbber_tick, %{pending1 | datagrid_state: nil})
      assert is_reference(ticked.throbber_timer)
      Process.cancel_timer(ticked.throbber_timer)

      {:noreply, after_turn1} =
        App.handle_info(
          {:ai_task_finished, req1, :sql, tab_id, "m1",
           {:ok,
            %{
              sql: "SELECT * FROM users;",
              is_read_only: true,
              explanation: "List all users",
              session_id: "sess-1"
            }}},
          pending1
        )

      tab_after_1 = Enum.find(after_turn1.tabs, &(&1.id == tab_id))
      assert tab_after_1.content == "SELECT * FROM users;"
      assert tab_after_1.ai_session_id == "sess-1"
      assert tab_after_1.ai_applied_msg_id == "m1"

      # Second turn replaces editor with DELETE (warns WRITE/DDL)
      req2 = make_ref()

      pending2 =
        after_turn1
        |> update_in([Access.key(:tabs), Access.at(1), :ai_messages], fn msgs ->
          msgs ++
            [
              %{
                id: "m2",
                prompt: "delete user 9",
                sql: nil,
                is_read_only: true,
                explanation: nil,
                error: nil,
                status: :running
              }
            ]
        end)
        |> Map.put(:ai_request, %{id: req2, pid: self(), tab_id: tab_id, msg_id: "m2"})

      {:noreply, after_turn2} =
        App.handle_info(
          {:ai_task_finished, req2, :sql, tab_id, "m2",
           {:ok,
            %{
              sql: "DELETE FROM users WHERE id = 9;",
              is_read_only: false,
              explanation: "Delete user 9",
              session_id: "sess-1"
            }}},
          pending2
        )

      assert after_turn2.status_message =~ "WRITE/DDL"

      assert Enum.find(after_turn2.tabs, &(&1.id == tab_id)).content ==
               "DELETE FROM users WHERE id = 9;"

      # User changes mind: presses Up from input -> history, picks turn #1, presses Enter -> re-applies SQL #1
      in_history =
        after_turn2
        |> Map.put(:focus, :ai_panel)
        |> Map.put(:ai_panel_focus, :input)
        |> App.handle_key(:up)

      assert in_history.ai_panel_focus == :history
      assert in_history.ai_selected_msg_idx == 1

      picked_turn1 =
        in_history
        |> App.handle_key(:up)
        |> App.handle_key(:enter)

      assert picked_turn1.ai_selected_msg_idx == 0
      reverted_tab = Enum.find(picked_turn1.tabs, &(&1.id == tab_id))
      assert reverted_tab.content == "SELECT * FROM users;"
      assert reverted_tab.ai_applied_msg_id == "m1"

      # Toggle close via Ctrl+O when already focused in :ai_panel
      closed = App.handle_key(picked_turn1, {:ctrl, "o"})
      assert closed.ai_panel_open == false
      assert closed.focus == :editor

      # Ctrl+L resets conversation (clears ai_messages & ai_session_id)
      reset_app = App.handle_key(picked_turn1, {:ctrl, "l"})
      reset_tab = Enum.find(reset_app.tabs, &(&1.id == tab_id))
      assert reset_tab.ai_messages == []
      assert reset_tab.ai_session_id == nil

      # Long multi-line SQL in conversation is wrapped cleanly without truncation
      long_sql =
        "SELECT id, email, created_at, updated_at, status FROM users WHERE status = 'active' ORDER BY created_at DESC;"

      long_tab = %{
        tab_after_1
        | ai_messages: [
            %{
              id: "m_long",
              prompt: "long",
              sql: long_sql,
              is_read_only: true,
              explanation: "Full query",
              error: nil,
              status: :done
            }
          ]
      }

      hist =
        AIChatPanel.history_data(%{picked_turn1 | ai_panel_focus: :history}, long_tab, %{
          x: 0,
          y: 0,
          width: 34,
          height: 12
        })

      rendered_sql_text =
        Enum.map_join(hist.lines, "\n", fn l -> Enum.map_join(l.spans, & &1.content) end)

      assert rendered_sql_text =~ "ORDER BY"
      assert rendered_sql_text =~ "created_at DESC;"
      refute rendered_sql_text =~ "…"
    end

    test "collapses long pasted lists into an inline pill and expands on submit" do
      app =
        App.new(window_size: {120, 40}, ai_panel_open: true, focus: :ai_panel)
        |> App.handle_key("f")
        |> App.handle_key("i")
        |> App.handle_key("n")
        |> App.handle_key("d")
        |> App.handle_key(" ")

      big_list = Enum.map_join(1..20, "\n", &"id_#{&1}")

      {:noreply, pasted} = App.handle_event(%ExRatatui.Event.Paste{content: big_list}, app)
      assert pasted.ai_input_text == "find [Pasted #1 +19 lines]"
      assert Map.get(pasted.ai_pastes, "[Pasted #1 +19 lines]") == big_list

      # Cursor jumps atomically left over the pill and Backspace deletes the entire pill
      jumped_left = App.handle_key(pasted, :left)
      assert jumped_left.ai_input_cursor == String.length("find ")

      deleted = App.handle_key(pasted, :backspace)
      assert deleted.ai_input_text == "find "
      assert deleted.ai_pastes == %{}

      # Expanding restores the full pasted list before sending to AI CLI
      expanded = AIChatPanel.expand_pastes(pasted.ai_input_text, pasted.ai_pastes)
      assert expanded == "find " <> big_list

      # Short paste inserts inline without collapsing
      short_pasted = App.paste_text(app, "users")
      assert short_pasted.ai_input_text == "find users"
      assert short_pasted.ai_pastes == %{}
    end

    test "archives closed non-empty SQL tabs and opens SQLTabPickerModal on Ctrl+T to reopen or create new" do
      app = App.new(window_size: {120, 40})
      blank_id = app.active_tab_id

      # Closing blank query tab does NOT clutter closed_tabs
      app_with_two = App.open_tab(app, name: "Query 2", content: "SELECT * FROM invoices;")
      q2_id = app_with_two.active_tab_id

      after_close_blank = App.close_tab(app_with_two, blank_id)
      assert after_close_blank.closed_tabs == []

      # Closing Query 2 (with AI chat history) archives both SQL and AI messages
      ai_turn = %{
        id: "m_saved",
        prompt: "list invoices",
        sql: "SELECT * FROM invoices;",
        is_read_only: true,
        explanation: "Fetch all invoices",
        error: nil,
        status: :done
      }

      app_with_q2_ai =
        Enum.map(after_close_blank.tabs, fn t ->
          if t.id == q2_id do
            %{
              t
              | cursor: {0, 7},
                ai_session_id: "sess_inv",
                ai_applied_msg_id: "m_saved",
                ai_messages: [ai_turn]
            }
          else
            t
          end
        end)
        |> then(&%{after_close_blank | tabs: &1})

      after_close_q2 = App.close_tab(app_with_q2_ai, q2_id)
      assert [closed_entry] = after_close_q2.closed_tabs
      assert closed_entry.name == "Query 2"
      assert closed_entry.content == "SELECT * FROM invoices;"
      assert length(closed_entry.ai_messages) == 1
      assert is_binary(closed_entry.closed_at) and closed_entry.closed_at != ""

      # Ctrl+T now opens SQLTabPickerModal (default item 0 is + New Blank SQL Tab)
      with_picker = App.handle_key(after_close_q2, {:ctrl, "t"})
      assert [%SQLTabPickerModal{} = picker] = with_picker.modals
      items = SQLTabPickerModal.visible_items(picker)
      assert hd(items).kind == :new_blank
      assert Enum.at(items, 1).label =~ "SELECT * FROM invoices;"

      # Renders cleanly as a styled List modal (not raw inspect fallback)
      frame = %ExRatatui.Frame{width: 120, height: 40}
      widgets = App.render(with_picker, frame)

      assert Enum.any?(widgets, fn
               {%ExRatatui.Widgets.List{block: %ExRatatui.Widgets.Block{title: title}}, _rect} ->
                 is_binary(title) and String.contains?(title, "SQL Tabs")

               _ ->
                 false
             end)

      session = ExRatatui.CellSession.new(120, 40)
      assert :ok == ExRatatui.CellSession.draw(session, widgets)

      # Search filter narrows closed tabs, Esc clears filter first, Down + Enter reopens closed tab
      filtered = App.handle_key(with_picker, "i") |> App.handle_key("n") |> App.handle_key("v")
      assert [%SQLTabPickerModal{filter: "inv"}] = filtered.modals
      assert length(SQLTabPickerModal.visible_items(hd(filtered.modals))) == 2

      cleared_filter = App.handle_key(filtered, :esc)
      assert [%SQLTabPickerModal{filter: ""}] = cleared_filter.modals

      reopened =
        cleared_filter
        |> App.handle_key(:down)
        |> App.handle_key(:enter)

      assert reopened.modals == []
      assert reopened.closed_tabs == []
      active = Enum.find(reopened.tabs, &(&1.id == reopened.active_tab_id))
      assert active.name == "Query 2"
      assert active.content == "SELECT * FROM invoices;"
      assert active.cursor == {0, 7}
      assert active.ai_session_id == "sess_inv"
      assert active.ai_applied_msg_id == "m_saved"
      assert active.ai_messages == [ai_turn]
      assert reopened.ai_panel_open == true

      # Ctrl+D inside picker deletes a closed tab entry
      closed_again = App.close_tab(reopened, reopened.active_tab_id)
      picker_again = App.handle_key(closed_again, {:ctrl, "t"})
      deleted_picker = picker_again |> App.handle_key(:down) |> App.handle_key({:ctrl, "d"})
      assert deleted_picker.closed_tabs == []
    end

    test "scopes SQLTabPickerModal recent queries to the currently selected database" do
      prof_a = %Strata.ConnectionProfile{
        id: "picker_db_a_#{System.unique_integer([:positive])}",
        name: "DB A",
        driver: :sqlite,
        database: ":memory:"
      }

      prof_b = %Strata.ConnectionProfile{
        id: "picker_db_b_#{System.unique_integer([:positive])}",
        name: "DB B",
        driver: :sqlite,
        database: ":memory:"
      }

      :ok = Strata.ConfigStore.put_profile(prof_a)
      :ok = Strata.ConfigStore.put_profile(prof_b)

      on_exit(fn ->
        Strata.ConfigStore.delete_profile(prof_a.id)
        Strata.ConfigStore.delete_profile(prof_b.id)
      end)

      app = App.new(window_size: {120, 40}, selected_tree_node_id: prof_a.id)
      # Close a non-empty SQL tab while DB A is selected
      app_a = App.open_tab(app, name: "A Query", content: "SELECT * FROM a_users;")
      tab_a_id = app_a.active_tab_id
      closed_a = App.close_tab(app_a, tab_a_id)
      assert [%{profile_id: pid_a}] = closed_a.closed_tabs
      assert pid_a == prof_a.id

      # Switching to DB B and pressing Ctrl+T opens a blank tab immediately (no DB A queries shown)
      on_db_b = %{closed_a | selected_tree_node_id: prof_b.id}
      new_on_b = App.handle_key(on_db_b, {:ctrl, "t"})
      assert new_on_b.modals == []
      assert Enum.find(new_on_b.tabs, &(&1.id == new_on_b.active_tab_id)).profile_id == prof_b.id

      # Close a query on DB B as well
      b_tab_id = new_on_b.active_tab_id

      b_with_sql =
        Enum.map(new_on_b.tabs, fn t ->
          if t.id == b_tab_id, do: %{t | content: "SELECT * FROM b_orders;"}, else: t
        end)
        |> then(&%{new_on_b | tabs: &1})

      closed_both = App.close_tab(b_with_sql, b_tab_id)
      assert length(closed_both.closed_tabs) == 2

      # Picker on DB B only shows DB B's closed query
      picker_b = App.handle_key(%{closed_both | selected_tree_node_id: prof_b.id}, {:ctrl, "t"})
      assert [%SQLTabPickerModal{} = modal_b] = picker_b.modals
      items_b = SQLTabPickerModal.visible_items(modal_b)
      assert length(items_b) == 2
      assert Enum.at(items_b, 1).label =~ "SELECT * FROM b_orders;"
      refute Enum.any?(items_b, &(&1.label =~ "a_users"))

      # Picker on DB A only shows DB A's closed query
      picker_a = App.handle_key(%{closed_both | selected_tree_node_id: prof_a.id}, {:ctrl, "t"})
      assert [%SQLTabPickerModal{} = modal_a] = picker_a.modals
      items_a = SQLTabPickerModal.visible_items(modal_a)
      assert length(items_a) == 2
      assert Enum.at(items_a, 1).label =~ "SELECT * FROM a_users;"
      refute Enum.any?(items_a, &(&1.label =~ "b_orders"))

      # Deleting DB A's closed entry does NOT remove DB B's closed entry
      after_del_a = picker_a |> App.handle_key(:down) |> App.handle_key({:ctrl, "d"})
      assert [%{profile_id: remaining_pid}] = after_del_a.closed_tabs
      assert remaining_pid == prof_b.id
    end

    test "handles Vietnamese NFC, NFD combining marks, Telex backspace, and multi-grapheme IME input in Ask AI" do
      alias ExRatatui.Event.Key

      app = App.new(window_size: {120, 40}, ai_panel_open: true, focus: :ai_panel)

      # 1. Telex-style backspace + precomposed UTF-8: t -> o -> backspace -> ô -> i
      {:noreply, t1} = App.handle_event(%Key{code: "t", kind: "press"}, app)
      {:noreply, t2} = App.handle_event(%Key{code: "o", kind: "press"}, t1)
      {:noreply, t3} = App.handle_event(%Key{code: "backspace", kind: "press"}, t2)
      {:noreply, t4} = App.handle_event(%Key{code: "ô", kind: "press"}, t3)
      {:noreply, t5} = App.handle_event(%Key{code: "i", kind: "press"}, t4)

      assert t5.ai_input_text == "tôi"
      assert t5.ai_input_cursor == 3

      # 2. NFD combining mark inserted in the middle normalizes to NFC and keeps exact cursor position
      mid = %{app | ai_input_text: "ab", ai_input_cursor: 1}
      {:noreply, m1} = App.handle_event(%Key{code: "\u0301", kind: "press"}, mid)
      assert m1.ai_input_text == "áb"
      assert m1.ai_input_cursor == 1

      {:noreply, m2} = App.handle_event(%Key{code: "x", kind: "press"}, m1)
      assert m2.ai_input_text == "áxb"
      assert m2.ai_input_cursor == 2

      # 3. Multi-grapheme committed IME text event is accepted cleanly
      {:noreply, ime} = App.handle_event(%Key{code: "tiếng Việt", kind: "press"}, app)
      assert ime.ai_input_text == "tiếng Việt"
      assert ime.ai_input_cursor == 10
    end
  end
end
