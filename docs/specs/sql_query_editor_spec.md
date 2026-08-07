# Spec: Multi-Tab SQL Query Editor & Execution System

## Objective
Complete the SQL Query Editor component in `Strata` to support full interactive database querying. Users can edit multi-line SQL queries with syntax highlighting, manage multiple query tabs (`Ctrl+T`, `Ctrl+W`, tab switching, mouse selection), and execute queries via `F5` or `Ctrl+Enter`. Query results are rendered directly in the `DataGrid` component with status execution timing and error reporting.

---

## Assumptions Made
1. **Active Connection Resolution**: When running a query in `:editor` mode, the app executes against the connection profile currently selected in the sidebar tree view (or the first available profile if none is selected).
2. **Query Execution Engine**: Query execution delegates to `Strata.ConnectionWorker.execute_query/3` (which already supports PostgreSQL, MySQL, and SQLite).
3. **Data Grid Integration**: On query completion, query columns and rows update `app.datagrid_state` and set `app.active_view` to `:query_view`.
4. **Tab Bar UI**: The SQL Editor component will render a clean, visual tab header bar at the top of the editor block showing `[ Tab Name ]`, active state highlights, and tab count.

---

## Tech Stack
- **Language**: Elixir 1.15+ (OTP 26+)
- **TUI Renderer**: `ExRatatui` / Ratatui NIF engine
- **Database Adapters**: `Postgrex`, `MyXQL`, `Exqlite` via `Strata.ConnectionWorker`
- **Testing**: `ExUnit`

---

## Commands
```bash
# Compile project
mix compile

# Run full test suite
mix test

# Run SQL Editor component tests specifically
mix test test/strata/ui/sql_editor_test.exs test/strata/ui/app_test.exs

# Run TUI application in dev mode
mix strata
```

---

## Project Structure
```text
lib/
└── strata/
    ├── ui/
    │   ├── app.ex                      # Key handling (F5, Ctrl+Enter, Ctrl+T, Ctrl+W, Tab navigation), query dispatch state
    │   ├── renderer.ex                 # Renders editor block with Tab Bar and syntax-highlighted editor content
    │   └── components/
    │       ├── sql_editor.ex           # Editor core: tokenizer, multi-tab state helper, tab bar layout, key actions
    │       └── data_grid.ex            # Renders query results
    └── connection_worker.ex           # Handles async query execution against live DB driver
test/
└── strata/
    └── ui/
        ├── sql_editor_test.exs         # Unit tests for SQL editor tokenizing, tab management, query dispatch
        └── app_test.exs                # Integration tests for key handling and execution workflows
```

---

## Code Style & Conventions
- Pure Elixir functions with clear spec type annotations `@spec`.
- Immutable state transformations in `App` and `SQLEditor`.
- Clean pattern matching for key handling (`:f5`, `{:ctrl, "r"}`, `{:ctrl, "t"}`, `{:ctrl, "w"}`).

```elixir
# Example snippet for query execution handling in SQLEditor / App
@spec execute_active_query(App.t()) :: App.t()
def execute_active_query(%App{tabs: tabs, active_tab_id: active_id} = app) do
  active_tab = Enum.find(tabs, &(&1.id == active_id))

  if active_tab && String.trim(active_tab.content) != "" do
    run_query(app, active_tab.content)
  else
    %{app | status_message: "Cannot execute empty query"}
  end
end
```

---

## Testing Strategy
1. **Unit Tests (`sql_editor_test.exs`)**:
   - Multi-tab lifecycle: `open_tab`, `close_tab`, `switch_tab`, tab clamping.
   - Key handling: typing, newlines, indenting (`Tab`), deletion, cursor navigation across multi-line queries.
   - Tab header bar rendering map creation.
2. **Integration Tests (`app_test.exs`)**:
   - `F5` / `Ctrl+Enter` key triggers query execution against `ConnectionWorker`.
   - Result update: `datagrid_state` is updated with returned columns & rows, and execution status message is recorded.
   - Error handling: SQL syntax error returns readable error message in status bar without crashing TUI.

---

## Boundaries
- **Always do**:
  - Keep 60 FPS rendering latency low.
  - Return clear, human-readable error messages on invalid SQL queries.
  - Maintain test coverage for all new tab management & query execution functions.
- **Ask first**:
  - Modifying DB driver connections or `ConnectionWorker` internal GenServer callbacks.
- **Never do**:
  - Block the main TUI UI process on slow DB queries (use non-blocking call/async task handling if required).
  - Mutate global state unsafely outside OTP process boundaries.

---

## Success Criteria
1. **Query Execution (`F5` / `Ctrl+Enter`)**: Pressing `F5` or `Ctrl+Enter` while focused in `:editor` mode executes the SQL query in the active tab and populates the `DataGrid` with rows/columns.
2. **Execution Timing & Status**: Displays execution statistics (e.g. `Query executed in 14ms (25 rows)`) or error diagnostics in the status bar.
3. **Tab Bar Header UI**: Visual tab header rendered above the SQL editor listing all open tabs with active indicator (`★ Query 1`).
4. **Tab Management**: Support `Ctrl+T` (new query tab), `Ctrl+W` (close current tab), `Alt+1..9` / `Tab` tab switching, and mouse clicking on tab headers.
5. **Indentation & Formatting**: Support `Tab` key insertion (2 spaces) when editing inside `:editor` without breaking pane focus cycling (which uses `Tab` when focused elsewhere or via `Shift+Tab` / `Ctrl+Tab`).
6. **100% Test Suite Pass**: All unit & integration tests pass cleanly with `mix test`.
