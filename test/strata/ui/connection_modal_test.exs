defmodule Strata.UI.Components.ConnectionModalTest do
  use ExUnit.Case, async: true
  alias Strata.UI.Components.ConnectionModal
  alias Strata.ConnectionProfile

  describe "new/1 & to_profile/1" do
    test "initializes default connection modal state" do
      modal = ConnectionModal.new()
      assert modal.driver == :postgres
      assert modal.host == "localhost"
      assert modal.port == 5432
      assert modal.focused_field == :name
      assert modal.status == :idle
      assert modal.status_message == nil
    end

    test "initializes from existing ConnectionProfile struct" do
      profile = %ConnectionProfile{
        id: "prod_db",
        name: "Prod DB",
        driver: :mysql,
        host: "db.internal",
        port: 3306,
        database: "app_prod",
        username: "admin",
        password: "secretpassword",
        ssh_profile_id: "ssh_bastion"
      }

      modal = ConnectionModal.new(profile: profile)
      assert modal.id == "prod_db"
      assert modal.name == "Prod DB"
      assert modal.driver == :mysql
      assert modal.host == "db.internal"
      assert modal.port == 3306
      assert modal.database == "app_prod"
      assert modal.ssh_profile_id == "ssh_bastion"
    end

    test "to_profile converts modal state to ConnectionProfile" do
      modal = ConnectionModal.new(
        name: "Test Postgres",
        driver: :postgres,
        host: "10.0.0.1",
        port: 5432,
        database: "mydb",
        username: "postgres",
        password: "pass",
        ssh_profile_id: "bastion"
      )

      profile = ConnectionModal.to_profile(modal)
      assert profile.name == "Test Postgres"
      assert profile.driver == :postgres
      assert profile.host == "10.0.0.1"
      assert profile.port == 5432
      assert profile.database == "mydb"
      assert profile.username == "postgres"
      assert profile.password == "pass"
      assert profile.ssh_profile_id == "bastion"
    end
  end

  describe "handle_key/2 field navigation and input" do
    test "navigates focused fields with tab and shift_tab / arrows" do
      modal = ConnectionModal.new()
      assert modal.focused_field == :name

      modal = ConnectionModal.handle_key(modal, :tab)
      assert modal.focused_field == :driver

      modal = ConnectionModal.handle_key(modal, :tab)
      assert modal.focused_field == :host

      modal = ConnectionModal.handle_key(modal, :shift_tab)
      assert modal.focused_field == :driver
    end

    test "cycles driver options when driver field is focused" do
      modal = ConnectionModal.new(driver: :postgres)
      modal = %{modal | focused_field: :driver}

      modal = ConnectionModal.handle_key(modal, :right)
      assert modal.driver == :mysql

      modal = ConnectionModal.handle_key(modal, :right)
      assert modal.driver == :sqlite

      modal = ConnectionModal.handle_key(modal, :right)
      assert modal.driver == :postgres
    end

    test "toggles ssl when ssl field is focused" do
      modal = ConnectionModal.new(ssl: false)
      modal = %{modal | focused_field: :ssl}

      modal = ConnectionModal.handle_key(modal, :space)
      assert modal.ssl == true

      modal = ConnectionModal.handle_key(modal, :space)
      assert modal.ssl == false
    end

    test "appends characters to focused text field" do
      modal = ConnectionModal.new(name: "DB", focused_field: :name)

      modal = ConnectionModal.handle_key(modal, "1")
      assert modal.name == "DB1"

      modal = ConnectionModal.handle_key(modal, :backspace)
      assert modal.name == "DB"
    end
  end

  describe "test_connection/2" do
    test "updates status to ok on successful test_fn call" do
      modal = ConnectionModal.new(name: "OK DB")

      test_fn = fn _profile -> :ok end
      modal = ConnectionModal.test_connection(modal, test_fn)

      assert modal.status == :ok
      assert modal.status_message =~ "Connection successful"
    end

    test "updates status to error on failed test_fn call" do
      modal = ConnectionModal.new(name: "Bad DB")

      test_fn = fn _profile -> {:error, "Access denied"} end
      modal = ConnectionModal.test_connection(modal, test_fn)

      assert modal.status == :error
      assert modal.status_message =~ "Access denied"
    end
  end

  describe "render/2" do
    test "returns structured map containing title and fields" do
      modal = ConnectionModal.new(name: "My DB")
      rendered = ConnectionModal.render(modal, %{width: 60, height: 20})

      assert rendered.title =~ "CONNECTION"
      assert is_list(rendered.fields)
      assert rendered.focused_field == :name
    end

    test "hides network/auth fields for sqlite driver and uses DB File Path label" do
      sqlite_modal = ConnectionModal.new(driver: :sqlite, database: "/tmp/app.db")
      fields = ConnectionModal.visible_fields(:sqlite)
      assert fields == [:name, :driver, :database, :test_button, :save_button, :cancel_button]

      rendered = ConnectionModal.render(sqlite_modal, %{width: 72, height: 22})
      labels = Enum.map(rendered.fields, & &1.label)
      assert "DB File Path" in labels
      refute "Host" in labels
      refute "Password" in labels
    end
  end

  describe "UX safeguards & URI parsing" do
    test "Enter in text field moves to next field instead of saving prematurely" do
      modal = ConnectionModal.new(focused_field: :host)
      next = ConnectionModal.handle_key(modal, :enter)
      assert %ConnectionModal{focused_field: :port} = next
    end

    test "cycling driver updates default port/database/username intelligently" do
      modal = ConnectionModal.new(driver: :postgres, focused_field: :driver)
      mysql_modal = ConnectionModal.handle_key(modal, :right)
      assert mysql_modal.driver == :mysql
      assert mysql_modal.port == 3306
      assert mysql_modal.username == "root"
      assert mysql_modal.database == ""
    end

    test "ignores free-text typing on :ssh_profile_id selector field" do
      modal = ConnectionModal.new(focused_field: :ssh_profile_id, ssh_profile_id: nil)
      after_type = ConnectionModal.handle_key(modal, "x")
      assert after_type.ssh_profile_id == nil
    end

    test "parse_uri & apply_uri populate Postgres/MySQL URIs and SQLite paths" do
      uri_modal = ConnectionModal.new() |> ConnectionModal.apply_uri("postgres://admin:s3cret@db.host:5433/prod?sslmode=require")
      assert uri_modal.driver == :postgres
      assert uri_modal.host == "db.host"
      assert uri_modal.port == 5433
      assert uri_modal.username == "admin"
      assert uri_modal.password == "s3cret"
      assert uri_modal.database == "prod"
      assert uri_modal.ssl == true

      sqlite_modal = ConnectionModal.new() |> ConnectionModal.apply_uri("/var/data/strata.sqlite")
      assert sqlite_modal.driver == :sqlite
      assert sqlite_modal.database == "/var/data/strata.sqlite"
    end
  end
end
