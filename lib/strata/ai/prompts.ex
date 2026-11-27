defmodule Strata.AI.Prompts do
  @moduledoc """
  System prompts and strict JSON Schemas for AI-assisted SQL Query Editor (`:sql`)
  and CLI health check (`:ping`) tasks.
  """

  @sql_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["sql", "is_read_only", "explanation"],
    "properties" => %{
      "sql" => %{"type" => "string"},
      "is_read_only" => %{"type" => "boolean"},
      "explanation" => %{"type" => "string"}
    }
  }

  @ping_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["ok"],
    "properties" => %{
      "ok" => %{"type" => "boolean"}
    }
  }

  @doc """
  Returns the JSON Schema string for SQL Editor responses.
  """
  @spec sql_json_schema() :: String.t()
  def sql_json_schema, do: Jason.encode!(@sql_schema)

  @doc """
  Returns the JSON Schema string for `[⚡ Test AI CLI]` ping checks.
  """
  @spec ping_json_schema() :: String.t()
  def ping_json_schema, do: Jason.encode!(@ping_schema)

  @doc """
  Returns the JSON Schema string for a given task type.
  """
  @spec json_schema(:sql | :ping) :: String.t()
  def json_schema(:sql), do: sql_json_schema()
  def json_schema(:ping), do: ping_json_schema()

  @doc """
  Builds the full prompt for a SQL Query Editor request using structured DB context.
  """
  @spec build_sql_prompt(map(), String.t()) :: String.t()
  def build_sql_prompt(context, user_request) do
    dialect = Map.get(context, :dialect, "SQL")
    table_ref = Map.get(context, :focused_table_ref, "(none)")
    schema_block = Map.get(context, :schema_summary, "(No schema metadata available)")
    current_sql = Map.get(context, :current_sql, "")
    last_error = Map.get(context, :last_error)

    sql_section =
      if String.trim(to_string(current_sql || "")) == "" do
        "(empty)"
      else
        String.trim(current_sql)
      end

    error_section =
      if is_binary(last_error) and String.trim(last_error) != "" do
        "\nLAST EXECUTION ERROR:\n#{String.trim(last_error)}\n"
      else
        ""
      end

    """
    You are a SQL assistant inside the `strata` TUI database manager.
    Generate or update a clean, executable #{dialect} SQL query based on the database schema and user request.

    STRICT OUTPUT RULES:
    - Return ONLY a JSON object matching the required schema.
    - `sql` MUST be clean executable #{dialect} SQL with NO markdown code fences (```) and end cleanly with `;`.
    - `is_read_only` MUST be `true` only for read-only queries (`SELECT`, `WITH ... SELECT`, `EXPLAIN`, `SHOW`, `PRAGMA` inspection), and `false` for any write/DDL statement (`INSERT`, `UPDATE`, `DELETE`, `DROP`, `ALTER`, `TRUNCATE`, `CREATE`).
    - Prefer accurate table/column names and JOIN keys from the provided schema context.
    - `explanation` should be a concise 1-sentence summary in the same language as the user request.

    TARGET DIALECT: #{dialect}
    FOCUSED TABLE: #{table_ref}

    DATABASE SCHEMA CONTEXT:
    #{schema_block}

    CURRENT SQL IN ACTIVE TAB:
    #{sql_section}
    #{error_section}
    USER REQUEST:
    #{String.trim(user_request)}
    """
  end

  @doc """
  Builds a minimal prompt used by `[⚡ Test AI CLI]`.
  """
  @spec build_ping_prompt() :: String.t()
  def build_ping_prompt do
    "Respond ONLY with JSON matching the schema: {\"ok\": true}."
  end
end
