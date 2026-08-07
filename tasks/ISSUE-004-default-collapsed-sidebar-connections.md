# [ISSUE-004] Default Collapsed State for Sidebar Connection Nodes

## 📌 Context & Problem Statement
Currently, when launching Strata, all database connection profiles in the Sidebar Schema Tree initialize with `expanded?: true` (expanded state).

If a user has multiple saved connection profiles (PostgreSQL, MySQL, SQLite) or large database schemas, the initial tree view becomes overly cluttered and long upon startup. Users must manually collapse connections to find the specific connection profile they want to work on.

---

## 🎯 Proposed Solution

### 1. 📁 Default Collapsed Connection Nodes
- Modify initial node construction in `Strata.UI.Components.Sidebar` (and `Strata.UI.App.init/1`) so all root connection profile nodes default to `expanded?: false`.
- On application launch, the sidebar presents a clean, compact list of connection profiles (e.g. `▶ Local Postgres`, `▶ Production MySQL`, `▶ SQLite Staging`).

### 2. ⚡ On-Demand Expansion
- Expanding a connection profile (and loading its database schemas/tables) occurs on-demand when the user:
  - Clicks on the connection node with mouse.
  - Presses `Enter` or Right Arrow (`→`) while focused on the connection node.
  - Double-clicks the connection profile.

---

## ✅ Acceptance Criteria (Definition of Done)

- [ ] **Clean Startup Tree**: Launching `mix strata` presents all connection profile nodes in collapsed state (`expanded?: false`).
- [ ] **On-Demand Expand**: Pressing `Enter`, `→`, or clicking a collapsed connection profile expands its schema tree and establishes/tests connection on demand.
- [ ] **State Preservation**: Collapsed state remains intact when switching between views or tabs.
- [ ] **Test Coverage**: Update unit tests in `test/strata/ui/components/sidebar_test.exs` or `app_test.exs` verifying:
  - Root connection nodes initialize with `expanded?: false`.
  - Toggle actions (`Enter` / `→`) change `expanded?` to `true`.

---

## 🛠️ Target Files & Modules

- 📄 [`lib/strata/ui/components/sidebar.ex`](file:///Users/quaywin/Projects_1/strata/lib/strata/ui/components/sidebar.ex)
  - Change default `expanded?: true` to `expanded?: false` in connection profile tree node constructors.
- 📄 [`lib/strata/ui/app.ex`](file:///Users/quaywin/Projects_1/strata/lib/strata/ui/app.ex)
  - Ensure initial state setup keeps connection nodes collapsed.
