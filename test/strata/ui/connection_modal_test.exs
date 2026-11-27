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
      modal =
        ConnectionModal.new(
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

    test "formats DBConnection.ConnectionError, Postgrex.Error, MyXQL.Error, and SSH tunnel errors cleanly" do
      modal = ConnectionModal.new(name: "PG DB")

      db_err = %DBConnection.ConnectionError{
        message: "tcp connect (127.0.0.1:5432): connection refused - :econnrefused"
      }

      pg_modal = ConnectionModal.test_connection(modal, fn _ -> {:error, db_err} end)
      assert pg_modal.status == :error

      assert pg_modal.status_message ==
               "❌ Connection failed: tcp connect (127.0.0.1:5432): connection refused - :econnrefused"

      refute pg_modal.status_message =~ "%DBConnection.ConnectionError"

      pg_auth_err =
        Postgrex.Error.exception(
          postgres: %{
            severity: "FATAL",
            code: "28P01",
            message: "password authentication failed for user \"postgres\""
          }
        )

      auth_modal = ConnectionModal.apply_test_result(modal, {:error, pg_auth_err})
      assert auth_modal.status == :error
      assert auth_modal.status_message =~ "password authentication failed"
      refute auth_modal.status_message =~ "%Postgrex.Error"

      ssh_modal =
        ConnectionModal.apply_test_result(modal, {:error, {:ssh_tunnel_failed, :econnrefused}})

      assert ssh_modal.status == :error

      assert ssh_modal.status_message ==
               "❌ Connection failed: SSH tunnel failed: Connection refused (:econnrefused)"

      sqlite_modal = ConnectionModal.apply_test_result(modal, {:error, :database_open_failed})

      assert sqlite_modal.status_message ==
               "❌ Connection failed: Failed to open SQLite database file"
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

      assert fields == [
               :name,
               :driver,
               :database,
               :auto_connect,
               :test_button,
               :save_button,
               :cancel_button
             ]

      rendered = ConnectionModal.render(sqlite_modal, %{width: 72, height: 22})
      labels = Enum.map(rendered.fields, & &1.label)
      assert "DB File Path" in labels
      assert "Auto-Connect" in labels
      refute "Host" in labels
      refute "Password" in labels
    end

    test "toggles auto_connect and persists it to ConnectionProfile" do
      modal = ConnectionModal.new()
      assert modal.auto_connect == false

      toggled = ConnectionModal.handle_key(%{modal | focused_field: :auto_connect}, :space)
      assert toggled.auto_connect == true

      prof = ConnectionModal.to_profile(toggled)
      assert prof.auto_connect == true

      reopened = ConnectionModal.new(profile: prof)
      assert reopened.auto_connect == true
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
      uri_modal =
        ConnectionModal.new()
        |> ConnectionModal.apply_uri("postgres://admin:s3cret@db.host:5433/prod?sslmode=require")

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

    test "navigates horizontally across action buttons with left and right arrows" do
      modal = ConnectionModal.new(focused_field: :test_button)
      m2 = ConnectionModal.handle_key(modal, :right)
      assert m2.focused_field == :save_button

      m3 = ConnectionModal.handle_key(m2, :right)
      assert m3.focused_field == :cancel_button

      m4 = ConnectionModal.handle_key(m3, :left)
      assert m4.focused_field == :save_button
    end

    test "supports cycling SSH tunnel between None, ~/.ssh/config profiles, and inline Manual SSH" do
      modal = ConnectionModal.new(focused_field: :ssh_profile_id)
      refute :ssh_host in ConnectionModal.visible_fields(modal)

      # Cycle forward from :none -> :manual (2nd option)
      manual_modal = ConnectionModal.handle_key(modal, :right)
      assert manual_modal.ssh_mode == :manual
      assert :ssh_host in ConnectionModal.visible_fields(manual_modal)
      assert :ssh_identity_file in ConnectionModal.visible_fields(manual_modal)

      # Type manual SSH details
      filled =
        manual_modal
        |> ConnectionModal.handle_key(:tab)
        |> ConnectionModal.handle_key("bastion.io")
        |> ConnectionModal.handle_key(:tab)
        |> ConnectionModal.handle_key(:backspace)
        |> ConnectionModal.handle_key(:backspace)
        |> ConnectionModal.handle_key("2222")
        |> ConnectionModal.handle_key(:tab)
        |> ConnectionModal.handle_key("deploy")
        |> ConnectionModal.handle_key(:tab)
        |> ConnectionModal.handle_key("pw")
        |> ConnectionModal.handle_key(:tab)
        |> ConnectionModal.handle_key("~/.ssh/id_ed25519")

      prof = ConnectionModal.to_profile(filled)
      assert prof.ssh_profile_id == nil

      assert prof.ssh == %{
               host: "bastion.io",
               port: 2222,
               username: "deploy",
               password: "pw",
               identity_file: "~/.ssh/id_ed25519"
             }

      # Re-opening from ConnectionProfile restores manual SSH mode and fields
      reopened = ConnectionModal.new(profile: prof)
      assert reopened.ssh_mode == :manual
      assert reopened.ssh_host == "bastion.io"
      assert reopened.ssh_port == 2222
      assert reopened.ssh_username == "deploy"
      assert reopened.ssh_password == "pw"
      assert reopened.ssh_identity_file == "~/.ssh/id_ed25519"

      # Cycling back to :none hides manual SSH fields cleanly
      none_modal =
        ConnectionModal.handle_key(%{reopened | focused_field: :ssh_profile_id}, :left)

      assert none_modal.ssh_mode == :none
      refute :ssh_host in ConnectionModal.visible_fields(none_modal)
    end

    test "exports dropdown_options and applies dropdown selection for :driver and :ssh_profile_id" do
      modal = ConnectionModal.new()

      driver_opts = ConnectionModal.dropdown_options(modal, :driver)
      assert Enum.map(driver_opts, & &1.value) == [:postgres, :mysql, :sqlite]
      assert Enum.find(driver_opts, & &1.selected?).value == :postgres

      mysql_modal = ConnectionModal.apply_dropdown_selection(modal, :driver, :mysql)
      assert mysql_modal.driver == :mysql
      assert mysql_modal.port == 3306
      assert mysql_modal.username == "root"

      ssh_opts = ConnectionModal.dropdown_options(mysql_modal, :ssh_profile_id)
      assert Enum.at(ssh_opts, 0).value == :none
      assert Enum.at(ssh_opts, 0).selected?
      assert Enum.at(ssh_opts, 1).value == :manual

      manual_modal =
        ConnectionModal.apply_dropdown_selection(mysql_modal, :ssh_profile_id, :manual)

      assert manual_modal.ssh_mode == :manual
      assert :ssh_host in ConnectionModal.visible_fields(manual_modal)
    end
  end
end
