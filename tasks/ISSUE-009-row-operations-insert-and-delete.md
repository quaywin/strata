# [ISSUE-009] Data Row Insertion & Deletion Operations

## 📌 Context & Problem Statement
With Issue 7 enabling inline cell editing, Strata needs complete record CRUD capability by allowing users to **insert new records** and **delete existing rows** directly from the DataGrid interface.

---

## 🎯 Proposed Solution & Workflow

### 1. ➕ New Row Insertion (`i` / `Ctrl+N`)
- **Trigger**: Press `i` or `Ctrl+N` while focused on DataGrid.
- **Behavior**:
  - Appends/inserts a new blank row at the top or bottom of the grid marked as `[+ Staged Insert]`.
  - Focuses the first editable cell automatically.
  - Newly inserted row is highlighted with a green border and `+` marker.

### 2. ❌ Row Deletion (`d` / `Delete`)
- **Trigger**: Press `d` or `Delete` on a selected row.
- **Behavior**:
  - Marks the selected row for deletion `[- Staged Delete]`.
  - Displays the row with a dimmed red strikethrough style (`~~row values~~`).
  - Pressing `d` again toggles/unmarks the deletion flag.

### 3. 💾 Batch Commit (`Ctrl+S`) & Integration with Staged System
- **Staged Actions Collection**:
  - Pending inserts: `INSERT INTO <table> (col1, col2) VALUES ($1, $2)`.
  - Pending deletes: `DELETE FROM <table> WHERE id = $1` (or full-row match).
- **Commit (`Ctrl+S`)**: Executes `INSERT` and `DELETE` queries within a database transaction block (where supported), updates ETS cache, and re-renders DataGrid.
- **Rollback (`Ctrl+Z`)**: Discards all pending inserts and deletes.

---

## ✅ Acceptance Criteria (Definition of Done)

- [ ] **Insert Row Shortcut**: Pressing `i` or `Ctrl+N` inserts a new row with green visual indicator.
- [ ] **Delete Row Shortcut**: Pressing `d` or `Delete` marks the row with red strikethrough.
- [ ] **Transaction Batch Commit**: `Ctrl+S` constructs parameterized `INSERT` and `DELETE` statements.
- [ ] **Rollback**: `Ctrl+Z` discards all pending inserts and deletes cleanly.
- [ ] **Test Coverage**: Unit tests added in `test/strata/ui/app_test.exs` and `connection_worker_test.exs` for insert & delete query generation and state transitions.

---

## 🛠️ Target Files & Modules

- 📄 [`lib/strata/ui/components/data_grid.ex`](file:///Users/quaywin/Projects_1/strata/lib/strata/ui/components/data_grid.ex)
  - Track `pending_inserts: [map()]` and `pending_deletes: MapSet.t()`.
- 📄 [`lib/strata/ui/app.ex`](file:///Users/quaywin/Projects_1/strata/lib/strata/ui/app.ex)
  - Handle `i`, `Ctrl+N`, `d`, `Delete` shortcuts.
- 📄 [`lib/strata/connection_worker.ex`](file:///Users/quaywin/Projects_1/strata/lib/strata/connection_worker.ex)
  - Support parameterized batch `INSERT` and `DELETE` executions.
