# [ISSUE-006] DBeaver-Style Column Sorting & Per-Column Inline Filtering

## 📌 Context & Problem Statement
Currently, users can only execute raw SQL queries or global filters to sort and filter tabular data. 

DBeaver and modern database GUI tools allow users to click directly on any column header (or hit a key shortcut while focusing a cell) to sort `ASC`/`DESC` or apply quick per-column filters without writing manual `WHERE` or `ORDER BY` clauses.

---

## 🎯 Proposed Solution & Feature Breakdown

### 1. 🔀 Column Level Sorting (ASC / DESC / Reset)
- **Trigger**: Click column header or press `s` (when in Select Mode on a column).
- **Cycle States**: `None` -> `ASC ▲` -> `DESC ▼` -> `None`.
- **Header Visuals**:
  - `user_id ▲` (Sorted Ascending)
  - `created_at ▼` (Sorted Descending)
- **Execution**: Automatically appends `ORDER BY <col> ASC/DESC` to the backend table query (or sorts ETS DataGrid rows in-memory for cached datasets).

### 2. 🔍 Per-Column Quick Filter Dialog (DBeaver Style)
- **Trigger**: Click filter icon next to column header or press `f` on a column.
- **Filter Modal/Popup**:
  - Shows target column name (e.g. `Filter [email]`).
  - **Operator Selector**: `=`, `CONTAINS` (`LIKE %val%`), `STARTS WITH`, `>`, `<`, `!=`, `IS NULL`, `IS NOT NULL`.
  - **Input Box**: Search pattern/value.
- **Header Visuals**: Indicates active filter on column header, e.g. `email 🔍[gemini]`.
- **Execution**: Appends `WHERE <col> LIKE '%val%'` to database query, preserving existing grid pagination and scrolling.

---

## ✅ Acceptance Criteria (Definition of Done)

- [ ] **Interactive Column Headers**: Clicking column headers toggles sort state (`ASC ▲` -> `DESC ▼` -> `Default`).
- [ ] **Visual Indicators**: Column headers render sort arrows (`▲`/`▼`) and filter badges (`🔍`) clearly.
- [ ] **Column Filter Popup**: Pressing `f` on a cell opens a column filter popup with operator dropdown and text input.
- [ ] **Compound Queries**: Multiple column filters and sorting can be combined (e.g. `status = 'active' ORDER BY created_at DESC`).
- [ ] **Reset Filter & Sort**: Shortcut (`Shift+F` or Clear Action) resets all active column filters and sorting back to original table order.
- [ ] **Test Coverage**: Unit tests in `test/strata/ui/components/data_grid_test.exs` verifying:
  - Column sort state cycling.
  - Column filter predicate evaluation and SQL `WHERE` / `ORDER BY` clause generation.

---

## 🛠️ Target Files & Modules

- 📄 [`lib/strata/ui/components/data_grid.ex`](file:///Users/quaywin/Projects_1/strata/lib/strata/ui/components/data_grid.ex)
  - Add `sort_columns: [{col_name, :asc | :desc}]` and `column_filters: %{col_name => {operator, value}}` fields to `%DataGrid{}`.
- 📄 [`lib/strata/ui/app.ex`](file:///Users/quaywin/Projects_1/strata/lib/strata/ui/app.ex)
  - Handle column header mouse click events and `f`/`s` keyboard shortcuts.
- 📄 [`lib/strata/ui/components/filter_export_modal.ex`](file:///Users/quaywin/Projects_1/strata/lib/strata/ui/components/filter_export_modal.ex)
  - Expand to support column-specific quick filter dialog.
