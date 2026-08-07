# [ISSUE-007] Inline Cell Editing & Staged Changes Commit System

## 📌 Context & Problem Statement
Currently, Strata allows browsing, inspecting cell details, sorting, and filtering table data. However, direct cell editing is not supported, forcing users to write manual `UPDATE <table> SET ...` SQL statements in the SQL Editor tab whenever they need to modify records.

To provide a modern, high-productivity TUI experience matching LazySQL, Harlequin, and DBeaver, Strata needs a keyboard-driven **Inline Cell Editing & Staged Changes Commit System**.

---

## 🎯 Proposed Solution & Architectural Design

### 1. ✏️ Dual Editing Triggers
- **Inline Cell Edit**: 
  - When in DataGrid Select Mode, pressing **`e`** or double-clicking a cell opens an inline input field overlay on the focused cell.
  - Pressing `Enter` confirms the cell edit (adds to staged changes).
  - Pressing `Esc` cancels editing the cell.
- **Cell Detail Inspector Edit**: 
  - Inside the Cell Detail Inspector modal, pressing **`e`** toggles editable text area mode for multi-line text, JSON, or UUID formatting.

### 2. 🟡 Staged Changes State Tracking (`pending_edits`)
- Uncommitted edits are stored in the DataGrid state map:
  ```elixir
  pending_edits: %{
    {row_index, col_name} => %{orig_value: "old", new_value: "new"}
  }
  ```
- **Visual Styling**: Cells with pending edits render with a distinct highlighted border (yellow/cyan) and a `*` dirty flag indicator (e.g. `john_doe*`).
- **Footer Status Bar**: Displays dirty edit count: `[ 💾 2 Pending Changes | Ctrl+S to Commit | Ctrl+Z to Revert ]`.

### 3. 💾 Batch Commit (`Ctrl+S`) & Rollback (`Ctrl+Z`)
- **Commit (`Ctrl+S`)**:
  - Automatically identifies primary key column (e.g. `id`) or falls back to full-row tuple matching.
  - Constructs parameterised `UPDATE <table> SET col1 = $1, col2 = $2 WHERE id = $3` statements via `ConnectionWorker`.
  - On successful DB execution: clears `pending_edits`, updates ETS cache, and displays notification `⚡ Successfully updated 2 rows`.
- **Rollback (`Ctrl+Z` / `Esc`)**:
  - Clears `pending_edits` map and restores original ETS cell values.

---

## ✅ Acceptance Criteria (Definition of Done)

- [ ] **Inline Editor Trigger**: Pressing `e` or double-clicking in Select Mode activates inline cell editing.
- [ ] **Dirty State Visuals**: Edited cells render yellow/cyan borders and a dirty `*` marker.
- [ ] **Staged Buffer**: Edits accumulate in `pending_edits` without altering DB immediately.
- [ ] **Commit via `Ctrl+S`**: `Ctrl+S` generates parameterized `UPDATE` queries using Primary Key or full-row matching.
- [ ] **Rollback via `Ctrl+Z`**: `Ctrl+Z` discards uncommitted edits and restores original table data.
- [ ] **Test Coverage**: Write unit tests in `test/strata/ui/components/data_grid_test.exs` and `app_test.exs` verifying:
  - Staging edits into `pending_edits`.
  - Parameterized `UPDATE` query generation.
  - Commit and rollback state transitions.

---

## 🛠️ Target Files & Modules

- 📄 [`lib/strata/ui/components/data_grid.ex`](file:///Users/quaywin/Projects_1/strata/lib/strata/ui/components/data_grid.ex)
  - Add `pending_edits: %{}` and `editing_cell: {row, col} | nil` to `%DataGrid{}`.
- 📄 [`lib/strata/ui/app.ex`](file:///Users/quaywin/Projects_1/strata/lib/strata/ui/app.ex)
  - Handle `e`, `Ctrl+S`, `Ctrl+Z` keybindings and mouse double-click cell edit event.
- 📄 [`lib/strata/ui/components/cell_detail_modal.ex`](file:///Users/quaywin/Projects_1/strata/lib/strata/ui/components/cell_detail_modal.ex)
  - Add edit mode toggle for cell inspector modal.
- 📄 [`lib/strata/connection_worker.ex`](file:///Users/quaywin/Projects_1/strata/lib/strata/connection_worker.ex)
  - Support parameterized `UPDATE` query execution.
