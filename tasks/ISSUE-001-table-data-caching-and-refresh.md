# [ISSUE-001] Table Data & Schema Caching with Instant Refresh Action

## 📌 Context & Problem Statement
Currently, whenever a user clicks or navigates to a table in the Schema Tree (or re-opens a table tab), Strata executes a full `SELECT * FROM <table> LIMIT ...` query against the database server. 

For remote databases connected via **SSH Tunneling** or high-latency connections, this causes noticeable rendering delays every time a table is selected. Re-querying unchanged tables creates unnecessary network overhead and degrades the 60 FPS TUI experience.

---

## 🎯 Proposed Feature Overview

### 1. ⚡ ETS Table Data Caching
- Implement cache layer in `Strata.DataStore` (or an ETS table) using a unique key: `{conn_id, schema_name, table_name}`.
- When clicking a table:
  - **Cache Hit**: Instantly retrieve and render the column headers and rows from ETS (`<1ms` latency) without querying the database.
  - **Cache Miss**: Execute the DB query, store the resulting `{columns, rows, total_count, fetched_at}` into ETS, and render.

### 2. 🔄 Refresh Action (Cache Invalidation)
- Add a dedicated **Refresh** action triggered via:
  - Keybinding: `r` (or `F5` / `Ctrl+R` when focused on DataGrid/Schema Tree).
  - TUI Header/Footer Action Button: `[🔄 Refresh]`.
- Pressing Refresh will:
  1. Invalidate/clear the ETS cache entry for the active table.
  2. Re-query the database for the latest records.
  3. Update ETS with new data.
  4. Display a status message: `⚡ Refreshed table 'users' (50 rows loaded at 17:05:20)`.

---

## ✅ Acceptance Criteria (Definition of Done)

- [ ] **Instant Re-navigation**: Re-selecting a previously loaded table loads data instantly from ETS cache without network roundtrips.
- [ ] **Connection-Aware Cache Isolation**: Cache entries are scoped per connection ID (`conn_id`) to prevent cross-database data leakage.
- [ ] **Refresh Keybinding & UI Action**: Keybinding `r` or `F5` forces a cache bypass and fetches fresh data from DB.
- [ ] **Status Indicator**: Status bar shows whether data was loaded from `Cache` or `DB` (e.g. `[Cache] users | 50 rows` vs `[DB] users | 50 rows`).
- [ ] **Test Coverage**: Write unit tests in `test/strata/data_store_test.exs` verifying:
  - Cache write & read hit.
  - Cache invalidation on refresh.

---

## 🛠️ Implementation References & Target Files

- 📄 [`lib/strata/data_store.ex`](file:///Users/quaywin/Projects_1/strata/lib/strata/data_store.ex)
  - Add helper `fetch_or_query_table_data/3` or cache lookup by `{conn_id, table_name}`.
- 📄 [`lib/strata/ui/app.ex`](file:///Users/quaywin/Projects_1/strata/lib/strata/ui/app.ex)
  - Intercept table selection events in Schema Tree & Tab navigation.
  - Handle `r` / `F5` event to trigger background/foreground refresh.
- 📄 [`lib/strata/connection_worker.ex`](file:///Users/quaywin/Projects_1/strata/lib/strata/connection_worker.ex)
  - Query execution entry point.
