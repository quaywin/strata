# Database TUI (`dbdata`) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a high-performance Database TUI Manager in Elixir with Ratatui, featuring SSH Tunneling, Schema Navigation, Tabbed SQL Editor, Paginated Data Grid, and Connection Modals inspired by DBeaver and Caudata.

**Architecture:** Fault-tolerant OTP Supervisor tree with `DynamicSupervisor` controlling DB connection workers (`Postgrex`, `MyXQL`, `Exqlite`), Erlang `:ssh` port forwarding for tunnels, and ETS direct-read tables for zero-latency 60 FPS TUI rendering.

**Tech Stack:** Elixir 1.19+, Erlang/OTP 28, `Postgrex`, `MyXQL`, `Exqlite`, Ratatui NIF (`ex_ratatui`), ETS Storage, Burrito single-binary packaging.

## Global Constraints

- Storage: User connection profiles and SSH profiles persisted under `~/.config/dbdata/`.
- Memory: RAM usage under 50MB during heavy data grid pagination.
- Rendering: Ratatui 60 FPS TUI render loop with SGR mouse support.

---

### Task 1: Project Scaffolding & Mix Dependencies

**Files:**
- Create: `mix.exs`
- Create: `config/config.exs`
- Create: `lib/db_data.ex`
- Create: `lib/db_data/application.ex`
- Test: `test/db_data_test.exs`

**Interfaces:**
- Consumes: Standard Mix project structure.
- Produces: `DBData.Application` entrypoint and supervised root tree.

- [ ] **Step 1: Write failing application startup test**

```elixir
defmodule DBDataTest do
  use ExUnit.Case
  doctest DBData

  test "application starts successfully" do
    assert {:ok, _pid} = Application.ensure_all_started(:db_data)
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/db_data_test.exs`
Expected: FAIL with module not found / app not configured

- [ ] **Step 3: Create mix.exs with required dependencies**

```elixir
defmodule DBData.MixProject do
  use Mix.Project

  def project do
    [
      app: :db_data,
      version: "0.1.0",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :ssh],
      mod: {DBData.Application, []}
    ]
  end

  defp deps do
    [
      {:postgrex, ">= 0.0.0"},
      {:myxql, ">= 0.0.0"},
      {:exqlite, "~> 0.13"},
      {:jason, "~> 1.4"},
      {:burrito, "~> 1.0", runtime: false}
    ]
  end
end
```

- [ ] **Step 4: Create DBData.Application supervisor**

```elixir
defmodule DBData.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {DynamicSupervisor, name: DBData.ConnectionSupervisor, strategy: :one_for_one}
    ]

    opts = [strategy: :one_for_one, name: DBData.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
```

- [ ] **Step 5: Run test to verify it passes**

Run: `mix test test/db_data_test.exs`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add mix.exs config/ lib/ test/
git commit -m "feat: setup initial mix project scaffolding and application supervisor"
```

---

### Task 2: Config Store & Models (DB & SSH Profiles)

**Files:**
- Create: `lib/db_data/connection_profile.ex`
- Create: `lib/db_data/ssh_profile.ex`
- Create: `lib/db_data/config_store.ex`
- Create: `lib/db_data/ssh_profile_store.ex`
- Test: `test/db_data/config_store_test.exs`

**Interfaces:**
- Consumes: `DBData.Application`
- Produces: `DBData.ConfigStore.get_profile/1`, `DBData.SSHProfileStore.list_profiles/0`

- [ ] **Step 1: Write test for ConfigStore & SSHProfileStore**

```elixir
defmodule DBData.ConfigStoreTest do
  use ExUnit.Case

  alias DBData.{ConfigStore, ConnectionProfile, SSHProfileStore, SSHProfile}

  test "stores and retrieves DB connection and SSH profiles" do
    ssh_prof = %SSHProfile{id: "ssh1", name: "My Server", host: "1.2.3.4", port: 22, username: "root"}
    assert :ok = SSHProfileStore.put_profile(ssh_prof)
    assert SSHProfileStore.get_profile("ssh1") == ssh_prof

    conn_prof = %ConnectionProfile{id: "conn1", name: "Prod PG", driver: :postgres, host: "localhost", port: 5432, ssh_profile_id: "ssh1"}
    assert :ok = ConfigStore.put_profile(conn_prof)
    assert ConfigStore.get_profile("conn1") == conn_prof
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/db_data/config_store_test.exs`
Expected: FAIL with missing modules

- [ ] **Step 3: Implement Profile Structs and ETS Config Stores**

Implement `DBData.ConnectionProfile`, `DBData.SSHProfile`, `DBData.ConfigStore` (GenServer with ETS table), and `DBData.SSHProfileStore` (GenServer with ETS table and `~/.ssh/config` parsing).

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/db_data/config_store_test.exs`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/db_data/ test/
git commit -m "feat: implement DB & SSH connection profile models and ETS stores"
```

---

### Task 3: DataStore & LogStore (ETS Direct Read)

**Files:**
- Create: `lib/db_data/data_store.ex`
- Create: `lib/db_data/log_store.ex`
- Test: `test/db_data/data_store_test.exs`
- Test: `test/db_data/log_store_test.exs`

**Interfaces:**
- Consumes: ETS tables created at startup
- Produces: `DBData.DataStore.store_result/3`, `DBData.DataStore.get_rows/2`, `DBData.LogStore.add_log/2`

- [ ] **Step 1: Write test for DataStore & LogStore**

```elixir
defmodule DBData.DataStoreTest do
  use ExUnit.Case
  alias DBData.{DataStore, LogStore}

  test "stores query result set and retrieves paginated rows" do
    columns = ["id", "email"]
    rows = [["1", "a@b.com"], ["2", "c@d.com"]]
    
    DataStore.put_result_set("tab1", columns, rows, 15)
    assert {^columns, [["1", "a@b.com"]], 2, 15} = DataStore.get_page("tab1", 1, 1)

    LogStore.add_log("tab1", %{status: :ok, query: "SELECT 1", duration_ms: 12, rows: 2})
    assert [%{query: "SELECT 1"}] = LogStore.get_logs("tab1")
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/db_data/data_store_test.exs`
Expected: FAIL

- [ ] **Step 3: Implement DataStore and LogStore circular buffer**

Implement `DBData.DataStore` and `DBData.LogStore` ETS table operations.

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/db_data/data_store_test.exs`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/db_data/data_store.ex lib/db_data/log_store.ex test/
git commit -m "feat: implement ETS DataStore and circular buffer LogStore"
```

---

### Task 4: ConnectionWorker & SSH Tunneling

**Files:**
- Create: `lib/db_data/connection_worker.ex`
- Create: `lib/db_data/ssh_tunnel.ex`
- Test: `test/db_data/connection_worker_test.exs`

**Interfaces:**
- Consumes: `DBData.ConnectionProfile`, `DBData.SSHProfileStore`
- Produces: `DBData.ConnectionWorker.execute_query/2`, `DBData.ConnectionWorker.test_connection/1`

- [ ] **Step 1: Write test for ConnectionWorker**

```elixir
defmodule DBData.ConnectionWorkerTest do
  use ExUnit.Case
  alias DBData.{ConnectionWorker, ConnectionProfile}

  test "connects to local sqlite database and executes query" do
    profile = %ConnectionProfile{id: "sqlite_test", name: "Test SQLite", driver: :sqlite, database: ":memory:"}
    {:ok, pid} = ConnectionWorker.start_link(profile)
    assert {:ok, %{columns: ["val"], rows: [[1]]}} = ConnectionWorker.execute_query(pid, "SELECT 1 as val")
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/db_data/connection_worker_test.exs`
Expected: FAIL

- [ ] **Step 3: Implement ConnectionWorker and SSHTunnel**

Implement GenServer handling `:postgres`, `:mysql`, `:sqlite` connection logic and SSH port forwarding via Erlang `:ssh`.

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/db_data/connection_worker_test.exs`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/db_data/connection_worker.ex lib/db_data/ssh_tunnel.ex test/
git commit -m "feat: implement ConnectionWorker and SSH tunnel manager"
```

---

### Task 5: TUI Core Engine, Main Layout & Keybindings

**Files:**
- Create: `lib/db_data/ui/app.ex`
- Create: `lib/db_data/ui/renderer.ex`
- Create: `lib/db_data/ui/components/sidebar.ex`
- Create: `lib/db_data/ui/components/footer.ex`

**Interfaces:**
- Consumes: Ratatui NIF engine & ETS stores
- Produces: Render loop, layout grid, sidebar navigation, keyboard/mouse event dispatcher.

- [ ] **Step 1: Implement TUI App State & Layout Redraw Loop**

Create `DBData.UI.App` managing active focus pane (`:sidebar`, `:editor`, `:datagrid`, `:modals`), active tabs, and SGR mouse handler.

- [ ] **Step 2: Implement Sidebar & Footer Components**

Render Tree View of DB connections and bottom action keys bar.

- [ ] **Step 3: Commit**

```bash
git add lib/db_data/ui/
git commit -m "feat: implement TUI core renderer, main layout, sidebar tree, and footer"
```

---

### Task 6: SQL Query Editor & Data Grid Panes

**Files:**
- Create: `lib/db_data/ui/components/sql_editor.ex`
- Create: `lib/db_data/ui/components/data_grid.ex`
- Create: `lib/db_data/ui/components/log_pane.ex`

**Interfaces:**
- Consumes: `DBData.ConnectionWorker`, `DBData.DataStore`
- Produces: Multi-tab SQL query text editing, syntax highlighting, and paginated table data grid.

- [ ] **Step 1: Implement SQL Editor Pane**
- [ ] **Step 2: Implement Data Grid Table & Pagination**
- [ ] **Step 3: Implement Execution Log Console**
- [ ] **Step 4: Commit**

```bash
git add lib/db_data/ui/components/
git commit -m "feat: implement SQL editor, data grid table, and query log pane"
```

---

### Task 7: Connection Modals & Cell Detail Inspector

**Files:**
- Create: `lib/db_data/ui/components/connection_modal.ex`
- Create: `lib/db_data/ui/components/ssh_modal.ex`
- Create: `lib/db_data/ui/components/cell_detail_modal.ex`
- Create: `lib/db_data/ui/components/filter_export_modal.ex`

**Interfaces:**
- Consumes: `DBData.ConfigStore`, `DBData.SSHProfileStore`
- Produces: Modal dialogues for Connection setup (`[ Test Connection ]`), SSH setup (`[ Test SSH ]`), Cell inspection (JSON/Text pretty print), and Export/Filter dialogs.

- [ ] **Step 1: Implement ConnectionModal & SSHProfileModal with Test Connection status**
- [ ] **Step 2: Implement CellDetailModal, FilterSortModal, and ExportModal**
- [ ] **Step 3: Commit**

```bash
git add lib/db_data/ui/components/
git commit -m "feat: implement connection modals, cell inspector, filter and export dialogs"
```

---

### Task 8: Single-Binary Packaging & End-to-End Verification

**Files:**
- Modify: `mix.exs`
- Create: `rel/env.sh.eex`

**Interfaces:**
- Consumes: Burrito release config
- Produces: Executable binary `dbdata` (~18MB).

- [ ] **Step 1: Configure Burrito release targets**
- [ ] **Step 2: Run build and verify standalone binary**

Run: `MIX_ENV=prod mix release`
Expected: Standalone binary generated in `burrito_out/`

- [ ] **Step 3: Commit**

```bash
git add mix.exs rel/
git commit -m "build: configure burrito release for single-binary distribution"
```
