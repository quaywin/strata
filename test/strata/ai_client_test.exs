defmodule Strata.AIClientTest do
  use ExUnit.Case, async: true

  alias Strata.AI.Client
  alias Strata.AI.CLIRunner
  alias Strata.AI.ContextBuilder
  alias Strata.AISettings
  alias Strata.DataStore
  alias Strata.UI.App
  alias Strata.UI.Components.DataGrid

  describe "ContextBuilder" do
    test "builds metadata-only context with focused table, FK related table, and active SQL error" do
      conn_id = "ai_ctx_#{System.unique_integer([:positive])}"

      DataStore.put_schema_cache(conn_id, "public", "orders", %{
        columns: ["Column", "Type", "Nullable", "Default", "Key", "Extra"],
        rows: [
          ["id", "bigint", "NO", nil, "PRI", ""],
          ["user_id", "bigint", "NO", nil, "FK", "-> users(id)"],
          ["total", "numeric", "NO", "0", "", ""]
        ],
        primary_keys: ["id"]
      })

      DataStore.put_schema_cache(conn_id, "public", "users", %{
        columns: ["Column", "Type", "Nullable", "Default", "Key", "Extra"],
        rows: [
          ["id", "bigint", "NO", nil, "PRI", ""],
          ["email", "text", "NO", nil, "", ""]
        ],
        primary_keys: ["id"]
      })

      on_exit(fn -> DataStore.invalidate_connection_cache(conn_id) end)

      profile = %Strata.ConnectionProfile{
        id: conn_id,
        name: "Prod",
        driver: :postgres,
        database: "shop"
      }

      Strata.ConfigStore.put_profile(profile)
      on_exit(fn -> Strata.ConfigStore.delete_profile(conn_id) end)

      nodes = [
        %{
          id: conn_id,
          label: "Prod",
          type: :connection,
          expanded?: true,
          children: [
            %{
              id: "#{conn_id}_public_tbl_orders",
              label: "orders",
              type: :table,
              profile_id: conn_id,
              schema: "public",
              children: []
            },
            %{
              id: "#{conn_id}_public_tbl_products",
              label: "products",
              type: :table,
              profile_id: conn_id,
              schema: "public",
              children: []
            }
          ]
        }
      ]

      app =
        App.new(
          selected_table: "orders",
          selected_schema: "public",
          selected_tree_node_id: "#{conn_id}_public_tbl_orders",
          sidebar_nodes: nodes,
          datagrid_state: DataGrid.new(["id", "user_id", "total"], [[1, 99, "SECRET_ROW_VALUE"]]),
          tabs: [
            %{
              id: "tab_1",
              kind: :query,
              name: "Query 1",
              content: "SELECT * FROM orders;",
              last_query_error: "column foo does not exist"
            }
          ],
          active_tab_id: "tab_1"
        )

      ctx =
        ContextBuilder.build(
          app,
          %AISettings{context_scope: :focused_and_related},
          fetch_missing?: false
        )

      assert ctx.dialect == "PostgreSQL"
      assert ctx.focused_table_ref == "public.orders"
      assert ctx.schema_summary =~ "FOCUSED TABLE public.orders"
      assert ctx.schema_summary =~ "-> users(id)"
      assert ctx.schema_summary =~ "RELATED TABLE public.users"
      assert ctx.schema_summary =~ "products"
      assert ctx.last_error == "column foo does not exist"
      refute ctx.schema_summary =~ "SECRET_ROW_VALUE"

      ctx_only =
        ContextBuilder.build(
          app,
          %AISettings{context_scope: :focused_only},
          fetch_missing?: false
        )

      refute ctx_only.schema_summary =~ "RELATED TABLE public.users"
    end
  end

  describe "Client command building & output parsing" do
    test "builds claude, codex, and agy commands with resume flags" do
      {:ok, {_, claude_args, _}} =
        Client.build_command(
          %AISettings{provider: :claude, model: "sonnet", keep_conversation: true},
          :sql,
          "hello",
          executable: "/usr/bin/claude",
          session_id: "sess-1"
        )

      assert "-p" in claude_args
      assert "--tools" in claude_args
      assert "--resume" in claude_args
      assert "sess-1" in claude_args
      assert "--model" in claude_args

      {:ok, {_, codex_args, codex_meta}} =
        Client.build_command(
          %AISettings{provider: :codex, model: "o3", keep_conversation: true},
          :sql,
          "hello",
          executable: "/usr/bin/codex",
          session_id: "thread-9"
        )

      on_exit(fn -> Enum.each(codex_meta.cleanup_files, &File.rm/1) end)
      assert Enum.take(codex_args, 2) == ["exec", "resume"]
      assert "thread-9" in codex_args
      assert "--output-schema" in codex_args

      {:ok, {_, agy_args, _}} =
        Client.build_command(
          %AISettings{provider: :agy, keep_conversation: true},
          :sql,
          "hello",
          executable: "/usr/bin/agy",
          session_id: "conv-7"
        )

      assert "--disable-slash-commands" in agy_args
      assert "--conversation" in agy_args
      assert "conv-7" in agy_args
    end

    test "parses claude, agy, and codex envelopes and normalizes SQL responses" do
      claude_raw =
        Jason.encode!(%{
          "is_error" => false,
          "session_id" => "claude-sess-42",
          "structured_output" => %{
            "sql" => "SELECT * FROM users WHERE status = 'active';",
            "is_read_only" => true,
            "explanation" => "Active users"
          }
        })

      settings = %AISettings{provider: :claude}
      ctx = %{dialect: "PostgreSQL", focused_table_ref: "public.users"}

      assert {:ok, claude_sql} =
               Client.generate_sql(settings, ctx, "active users",
                 executable: "/usr/bin/claude",
                 runner: fn _, _, _ -> {:ok, claude_raw} end
               )

      assert claude_sql.sql == "SELECT * FROM users WHERE status = 'active';"
      assert claude_sql.is_read_only == true
      assert claude_sql.session_id == "claude-sess-42"

      agy_raw =
        Jason.encode!(%{
          "status" => "SUCCESS",
          "conversation_id" => "agy-conv-99",
          "structured_output" => %{
            "sql" => "```sql\nDELETE FROM users WHERE id = 1;\n```",
            "is_read_only" => false,
            "explanation" => "Delete user 1"
          }
        })

      assert {:ok, sql_res} =
               Client.generate_sql(%AISettings{provider: :agy}, ctx, "delete user 1",
                 executable: "/usr/bin/agy",
                 runner: fn _, _, _ -> {:ok, agy_raw} end
               )

      assert sql_res.sql == "DELETE FROM users WHERE id = 1;"
      assert sql_res.is_read_only == false
      assert sql_res.session_id == "agy-conv-99"

      codex_jsonl =
        [
          Jason.encode!(%{"type" => "thread.started", "thread_id" => "codex-thread-5"}),
          Jason.encode!(%{
            "type" => "item.completed",
            "item" => %{
              "type" => "agent_message",
              "text" =>
                Jason.encode!(%{
                  "sql" => "SELECT 1;",
                  "is_read_only" => true,
                  "explanation" => "Ping"
                })
            }
          })
        ]
        |> Enum.join("\n")

      assert {:ok, codex_payload, "codex-thread-5"} =
               Client.parse_output(:codex, codex_jsonl, [])

      assert codex_payload["sql"] == "SELECT 1;"
    end

    test "surfaces CLI auth errors cleanly" do
      claude_err =
        Jason.encode!(%{
          "is_error" => true,
          "result" => "Not logged in · Please run /login"
        })

      assert {:error, "Not logged in · Please run /login"} =
               Client.parse_output(:claude, claude_err, [])
    end
  end

  describe "CLIRunner" do
    test "executes commands with closed stdin and handles timeouts" do
      assert {:ok, out} = CLIRunner.run("/bin/echo", ["strata_ok"], timeout_ms: 2_000)
      assert String.trim(out) == "strata_ok"

      assert {:error, :timeout} = CLIRunner.run("/bin/sleep", ["2"], timeout_ms: 100)
    end
  end
end
