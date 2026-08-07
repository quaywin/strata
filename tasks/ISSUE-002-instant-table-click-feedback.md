# [ISSUE-002] Optimistic UI & Non-Blocking Async Table Selection

## 📌 Context & Problem Statement
Currently, when a user clicks on a table node in the Sidebar Schema Tree:
1. `handle_mouse/2` in `lib/strata/ui/app.ex` calculates the target item and updates `selected_tree_node_id`.
2. It immediately invokes `Sidebar.load_table_data(app, target_item.label)` **synchronously** within the event loop handler.

If the database query takes `100ms - 1000ms` (e.g. over SSH tunnel or remote DB), the main TUI render loop is blocked. As a result, the user experiences a lag before the selected table node visually highlights, giving the impression that the mouse click was unresponsive or missed.

---

## 🎯 Proposed Solution & Architectural Design

### 1. ⚡ Optimistic Selection Highlight (Immediate State Update)
- Upon receiving a mouse click on a sidebar item (or pressing `Enter`), **immediately** update `selected_tree_node_id`, `sidebar_scroll_offset`, and set UI state flags:
  - `loading_table: target_item.label`
  - `active_view: :table_view`
- Render the updated TUI frame instantly (0ms latency), showing the table node highlighted in yellow/blue and displaying a `⏳ Loading table '<name>'...` indicator in the DataGrid or status bar.

### 2. 🔄 Asynchronous Data Fetching
- Offload `Sidebar.load_table_data/2` DB execution to an asynchronous process (e.g. `Task.async/1` or `send(self(), {:fetch_table_data, table_name})`).
- Once the background task fetches the data:
  - Put data into `Strata.DataStore` ETS cache.
  - Send message `{:table_data_loaded, table_name, columns, rows}` to `Strata.UI.App`.
  - Update state: clear `loading_table` flag, store rows, and re-render DataGrid smoothly.

---

## ✅ Acceptance Criteria (Definition of Done)

- [ ] **0ms Click Reaction**: Clicking any table node immediately highlights the selected tree row in the TUI without waiting for DB response.
- [ ] **Loading Feedback**: DataGrid area displays a clean loading spinner/message (`⏳ Fetching data for 'users'...`) while the query executes in background.
- [ ] **No UI Freeze**: Mouse and keyboard interactions remain responsive during background data loading.
- [ ] **Race Condition Safeguard**: If user clicks Table A and then rapidly clicks Table B before Table A finishes loading, only Table B's data should populate when complete.
- [ ] **Test Coverage**: Unit test in `test/strata/ui/app_test.exs` verifying state updates immediately on `:click` event before background data message is handled.

---

## 🛠️ Target Files & Modules

- 📄 [`lib/strata/ui/app.ex`](file:///Users/quaywin/Projects_1/strata/lib/strata/ui/app.ex)
  - Refactor `handle_mouse/2` sidebar click block to update `selected_tree_node_id` first, then trigger async fetch.
  - Handle asynchronous event `{:fetch_table_data, table_name}` or `Task` result message.
- 📄 [`lib/strata/ui/components/sidebar.ex`](file:///Users/quaywin/Projects_1/strata/lib/strata/ui/components/sidebar.ex)
  - Extract non-blocking `load_table_data_async/2` helper.
- 📄 [`lib/strata/ui/renderer.ex`](file:///Users/quaywin/Projects_1/strata/lib/strata/ui/renderer.ex)
  - Render loading placeholder state when `loading_table` is active.
