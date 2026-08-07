# [ISSUE-003] Auto Focus Switch to DataGrid & Animated Loading Indicator

## 📌 Context & Problem Statement
Currently, when a user selects a table from the Sidebar Schema Tree (by pressing `Enter` or clicking with mouse):
1. The table data begins loading, but the input focus (`app.focus`) remains on `:sidebar`. 
2. The user must manually press `Tab` to shift focus to `:datagrid` before they can navigate rows/cells, copy data, or inspect details.
3. While data is fetching, the DataGrid pane either displays blank content or stale data without a clear visual loading state.

---

## 🎯 Proposed Solution

### 1. 🎯 Auto-Focus Switch on Table Selection
- When selecting/opening any table (via mouse double-click, single click on table item, or pressing `Enter` on a tree node of type `:table`/`:view`):
  - Automatically update `focus: :datagrid` and `active_view: :table_view`.
  - Enable immediate keyboard controls (`↑`/`↓`, `PageUp`/`PageDown`, `v`, `s`, `c`, `Enter`) on the DataGrid right after selection.

### 2. ⏳ Visual Loading State Component
- Introduce a dedicated TUI **Loading Indicator** component rendered inside the DataGrid pane when data is loading (`loading: true` / `is_fetching: true`).
- Display:
  - Spinner/Status text: `[⏳ Loading data for 'table_name'...]`
  - Elapsed loading time indicator (e.g. `(0.4s)`).
  - Clean border rendering with dimmed background to signal active background fetching.

---

## ✅ Acceptance Criteria (Definition of Done)

- [ ] **Seamless Auto-Focus**: Pressing `Enter` or clicking a table item in Sidebar instantly moves active cursor focus to DataGrid (`focus: :datagrid`).
- [ ] **Immediate Navigation**: After opening a table, arrow keys (`↑`/`↓`) immediately scroll table rows without requiring an extra `Tab` keypress.
- [ ] **Clear Loading UI**: DataGrid pane shows an active loading message/spinner during network DB query execution instead of an empty/stale grid.
- [ ] **Smooth Transition**: Once data loading completes, the loading spinner seamlessly transitions to rendering the full DataGrid table rows.
- [ ] **Test Coverage**: Add test cases in `test/strata/ui/app_test.exs` verifying:
  - Sidebar table selection switches `focus` to `:datagrid`.
  - Loading state flag correctly toggles on/off.

---

## 🛠️ Target Files & Modules

- 📄 [`lib/strata/ui/app.ex`](file:///Users/quaywin/Projects_1/strata/lib/strata/ui/app.ex)
  - Update table selection action to set `focus: :datagrid` and `active_view: :table_view`.
- 📄 [`lib/strata/ui/renderer.ex`](file:///Users/quaywin/Projects_1/strata/lib/strata/ui/renderer.ex)
  - Add rendering logic for the DataGrid loading spinner overlay component.
- 📄 [`lib/strata/ui/components/data_grid.ex`](file:///Users/quaywin/Projects_1/strata/lib/strata/ui/components/data_grid.ex)
  - Support `loading` parameter in `DataGrid.render/3`.
