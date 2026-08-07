# Spec: SQL Query Editor Autocomplete Suggestions

## Objective
Implement an interactive SQL Autocomplete Suggestion Popup in the `Strata` SQL Query Editor. As the user types, the editor analyzes the word before the cursor, matches SQL keywords, database table names, and column names from the active schema, and displays a floating suggestion popup using `ExRatatui.Widgets.Clear` and `ExRatatui.Widgets.List`. Users can navigate suggestions with `Up`/`Down` arrows and apply completions using `Tab` or `Enter`.

---

## Assumptions Made
1. **Trigger Threshold**: Autocomplete triggers automatically when typing 1 or more letters/digits of an uncompleted word.
2. **Schema Scope**: Table and column suggestions are dynamically populated from `sidebar_nodes` (connection schema tree).
3. **Key Priority when Autocomplete Active**:
   - `Down` / `Up`: Navigates suggestion list items.
   - `Tab` / `Enter`: Inserts selected suggestion into the editor at cursor position and closes popup.
   - `Esc`: Closes popup without modifying text.
4. **UI Layout**: The completion popup renders as an overlay box anchored near the current editor line & column cursor position.

---

## Tech Stack
- **Language**: Elixir 1.15+ (OTP 26+)
- **UI Engine**: `ExRatatui` (`ExRatatui.Widgets.Clear`, `ExRatatui.Widgets.List`, `ExRatatui.Widgets.Block`)
- **Testing**: `ExUnit`

---

## Commands
```bash
# Compile project
mix compile

# Run full test suite
mix test

# Run completer & editor tests specifically
mix test test/strata/ui/sql_completer_test.exs test/strata/ui/sql_editor_test.exs
```

---

## Project Structure
```text
lib/
└── strata/
    └── ui/
        ├── components/
        │   ├── sql_completer.ex       # Keyword & schema autocomplete engine
        │   └── sql_editor.ex          # Multi-tab state & completion key handling
        └── renderer.ex                # Floating completion popup overlay rendering
test/
└── strata/
    └── ui/
        ├── sql_completer_test.exs     # Completer engine unit tests
        └── sql_editor_test.exs        # Editor autocompletion key integration tests
```

---

## Boundaries
- **Always do**:
  - Keep 60 FPS rendering latency low during typing and completion lookup.
  - Properly replace only the current word prefix when applying completion.
  - Automatically close popup on space, punctuation, or manual `Esc`.
- **Ask first**:
  - Adding network-based remote database schema introspection on every keypress.
- **Never do**:
  - Block editor keypress dispatch while computing completion matches.

---

## Success Criteria
1. Typing keywords (e.g. `SE`) or schema table names opens a completion popup near the cursor.
2. Navigating with `Up`/`Down` updates highlighted suggestion item.
3. Pressing `Tab` or `Enter` inserts completion text and advances cursor position.
4. All unit and integration tests pass 100% cleanly.
