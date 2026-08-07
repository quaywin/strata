# [ISSUE-008] Table Structure & Schema Details Inspector View

## 📌 Context & Problem Statement
Currently, selecting a table in Strata displays its data rows in the DataGrid. However, database developers frequently need to inspect column definitions, data types (`VARCHAR`, `BIGINT`, `TIMESTAMP`), nullability constraints, default values, primary keys, and index configurations without querying `information_schema` manually.

---

## 🎯 Proposed Solution

### 1. 🏗️ Dual Data / Structure View Switch
- Add a view mode toggle in the Table View pane:
  - **Data Mode** (`F2` / `d`): Shows standard tabular data rows (existing DataGrid).
  - **Structure Mode** (`F3` / `s`): Shows the Table Schema Structure Grid.

### 2. 📊 Schema Structure Grid Fields
When in Structure Mode, display a specialized DataGrid listing all column attributes:
- **Column Name** (e.g. `user_id`, `email`, `created_at`).
- **Data Type** (e.g. `BIGINT`, `VARCHAR(255)`, `TIMESTAMPTZ`).
- **Nullable** (`YES` / `NO`).
- **Key Type** (`PRIMARY KEY 🔑`, `FOREIGN KEY 🔗`, `UNIQUE 🔒`, `None`).
- **Default Value** (e.g. `nextval(...)`, `CURRENT_TIMESTAMP`, `NULL`).
- **Extra / Auto Increment** (e.g. `auto_increment`, `identity`).

### 3. 🔍 Database Driver Adapter Schema Inspection
- Extend `Strata.SchemaInspector` to query database-specific metadata:
  - **PostgreSQL**: Query `information_schema.columns` and `pg_index`.
  - **MySQL**: Query `information_schema.columns` and `SHOW KEYS FROM <table>`.
  - **SQLite**: Query `PRAGMA table_info(table_name)` and `PRAGMA index_list(table_name)`.

---

## ✅ Acceptance Criteria (Definition of Done)

- [ ] **Structure View Toggle**: Pressing `F3` or `s` in Table View switches between Data Grid and Structure Grid.
- [ ] **Multi-Database Support**: Schema inspector accurately parses column types, primary keys, and defaults for PostgreSQL, MySQL, and SQLite.
- [ ] **Visual Key Icons**: Primary keys display key badges (`🔑 PK`) and foreign keys display link badges (`🔗 FK`).
- [ ] **Test Coverage**: Write unit tests in `test/strata/schema_inspector_test.exs` verifying metadata retrieval across Postgres, MySQL, and SQLite adapters.

---

## 🛠️ Target Files & Modules

- 📄 [`lib/strata/schema_inspector.ex`](file:///Users/quaywin/Projects_1/strata/schema_inspector.ex)
  - Implement `fetch_table_schema/2` for columns, types, keys, and defaults.
- 📄 [`lib/strata/ui/app.ex`](file:///Users/quaywin/Projects_1/strata/lib/strata/ui/app.ex)
  - Handle `F2`/`F3` view toggle and render structure grid.
- 📄 [`lib/strata/ui/components/data_grid.ex`](file:///Users/quaywin/Projects_1/strata/lib/strata/ui/components/data_grid.ex)
  - Support rendering schema structure rows.
