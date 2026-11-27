defmodule Strata.WorkspaceStoreTest do
  use ExUnit.Case, async: false

  alias Strata.UI.App
  alias Strata.WorkspaceStore

  describe "WorkspaceStore persistence" do
    test "persists SQL query tabs and per-tab AI chat history across restarts" do
      tmp_path =
        Path.join(
          System.tmp_dir!(),
          "strata_workspace_test_#{System.unique_integer([:positive])}.json"
        )

      on_exit(fn -> File.rm(tmp_path) end)

      name = :"ws_store_#{System.unique_integer([:positive])}"
      {:ok, pid1} = WorkspaceStore.start_link(name: name, workspace_path: tmp_path)

      tabs = [
        %{
          id: "tab_1",
          kind: :table,
          name: "users",
          table_name: "users"
        },
        %{
          id: "tab_2",
          kind: :query,
          name: "Orders Report",
          profile_id: "conn_pg",
          content: "SELECT * FROM orders LIMIT 10;",
          cursor: {0, 12},
          ai_session_id: "sess-abc",
          ai_session_provider: :agy,
          ai_applied_msg_id: "m2",
          ai_messages: [
            %{
              id: "m1",
              prompt: "all orders",
              sql: "SELECT * FROM orders;",
              is_read_only: true,
              explanation: "List orders",
              error: nil,
              status: :done
            },
            %{
              id: "m2",
              prompt: "limit 10",
              sql: "SELECT * FROM orders LIMIT 10;",
              is_read_only: true,
              explanation: "Top 10 orders",
              error: nil,
              status: :done
            },
            %{
              id: "m3",
              prompt: "in flight",
              sql: nil,
              status: :running
            }
          ]
        }
      ]

      assert :ok == WorkspaceStore.save_sync(pid1, tabs, "tab_2")
      loaded = WorkspaceStore.load(pid1)
      assert loaded.active_tab_id == "tab_2"
      assert length(loaded.tabs) == 1
      assert loaded.closed_tabs == []
      [saved_q] = loaded.tabs
      assert saved_q.name == "Orders Report"
      assert saved_q.profile_id == "conn_pg"
      assert saved_q.content == "SELECT * FROM orders LIMIT 10;"
      assert saved_q.cursor == {0, 12}
      assert saved_q.ai_session_id == "sess-abc"
      assert saved_q.ai_session_provider == :agy
      assert saved_q.ai_applied_msg_id == "m2"
      # Running turns are filtered out on save
      assert length(saved_q.ai_messages) == 2

      # Persist closed_tabs with timestamp
      closed_entry = WorkspaceStore.build_closed_tab_entry(saved_q, "2026-11-27T15:54:00")
      assert closed_entry.closed_at == "2026-11-27T15:54:00"

      assert nil ==
               WorkspaceStore.build_closed_tab_entry(%{
                 kind: :query,
                 content: "   ",
                 ai_messages: []
               })

      # Deduplication preserves identical queries across different profile_ids
      entry_db_a =
        WorkspaceStore.build_closed_tab_entry(%{
          kind: :query,
          name: "Query 1",
          profile_id: "conn_a",
          content: "SELECT 1;",
          ai_messages: []
        })

      entry_db_b =
        WorkspaceStore.build_closed_tab_entry(%{
          kind: :query,
          name: "Query 1",
          profile_id: "conn_b",
          content: "SELECT 1;",
          ai_messages: []
        })

      combined =
        []
        |> WorkspaceStore.prepend_closed_tab(entry_db_a)
        |> WorkspaceStore.prepend_closed_tab(entry_db_b)

      assert length(combined) == 2

      assert :ok == WorkspaceStore.save_sync(pid1, [], nil, [closed_entry])
      GenServer.stop(pid1)

      {:ok, pid2} = WorkspaceStore.start_link(name: name, workspace_path: tmp_path)
      reloaded = WorkspaceStore.load(pid2)
      assert reloaded.tabs == []
      assert [reloaded_closed] = reloaded.closed_tabs
      assert reloaded_closed.content == "SELECT * FROM orders LIMIT 10;"
      assert reloaded_closed.closed_at == "2026-11-27T15:54:00"
      assert length(reloaded_closed.ai_messages) == 2
      GenServer.stop(pid2)
    end

    test "App restores workspace tabs on :bootstrap when WorkspaceStore has saved tabs" do
      # Save into the global WorkspaceStore and restore via :bootstrap
      q_tabs = [
        %{
          id: "tab_99",
          kind: :query,
          name: "Saved Query",
          profile_id: nil,
          content: "SELECT 42;",
          cursor: {0, 5},
          ai_session_id: "sess-99",
          ai_applied_msg_id: "m1",
          ai_messages: [
            %{
              id: "m1",
              prompt: "answer 42",
              sql: "SELECT 42;",
              is_read_only: true,
              explanation: "Returns 42",
              error: nil,
              status: :done
            }
          ]
        }
      ]

      WorkspaceStore.save_sync(q_tabs, "tab_99", nil, ai_panel_open: true)

      on_exit(fn ->
        WorkspaceStore.save_sync([], nil, [], ai_panel_open: false)
      end)

      app = App.new()
      {:noreply, bootstrapped} = App.handle_info(:bootstrap, app)
      assert bootstrapped.active_tab_id == "tab_99"
      assert bootstrapped.ai_panel_open == true

      assert [%{id: "tab_99", name: "Saved Query", content: "SELECT 42;"} = restored_tab] =
               bootstrapped.tabs

      assert length(restored_tab.ai_messages) == 1
      assert restored_tab.ai_session_id == "sess-99"
      assert restored_tab.ai_applied_msg_id == "m1"
    end
  end
end
