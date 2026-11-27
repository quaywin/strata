defmodule Strata.ConfigStoreTest do
  use ExUnit.Case

  alias Strata.{ConfigStore, ConnectionProfile, SSHProfileStore, SSHProfile}

  test "stores and retrieves DB connection and SSH profiles" do
    ssh_prof = %SSHProfile{
      id: "ssh1",
      name: "My Server",
      host: "1.2.3.4",
      port: 22,
      username: "root"
    }

    assert :ok = SSHProfileStore.put_profile(ssh_prof)
    assert SSHProfileStore.get_profile("ssh1") == ssh_prof
    assert ssh_prof in SSHProfileStore.list_profiles()

    conn_prof = %ConnectionProfile{
      id: "conn1",
      name: "Prod PG",
      driver: :postgres,
      host: "localhost",
      port: 5432,
      ssh_profile_id: "ssh1"
    }

    assert :ok = ConfigStore.put_profile(conn_prof)
    assert ConfigStore.get_profile("conn1") == conn_prof
    assert conn_prof in ConfigStore.list_profiles()
  end

  test "parses ~/.ssh/config contents" do
    sample_config = """
    Host myserver
      HostName 192.168.1.100
      User admin
      Port 2222
      IdentityFile ~/.ssh/id_rsa

    Host db-jump
      HostName jump.example.com
      User ec2-user
      Port 22
    """

    profiles = SSHProfileStore.parse_ssh_config_string(sample_config)
    assert length(profiles) == 2

    myserver = Enum.find(profiles, &(&1.name == "myserver"))
    assert myserver.host == "192.168.1.100"
    assert myserver.username == "admin"
    assert myserver.port == 2222
    assert myserver.identity_file == "~/.ssh/id_rsa"

    db_jump = Enum.find(profiles, &(&1.name == "db-jump"))
    assert db_jump.host == "jump.example.com"
    assert db_jump.username == "ec2-user"
    assert db_jump.port == 22
  end

  test "persists SSH profiles and ConfigStore profiles across restarts and guards option atoms" do
    tmp_dir =
      Path.join(System.tmp_dir!(), "strata_store_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf(tmp_dir) end)

    cfg_path = Path.join(tmp_dir, "config.db")
    json_path = Path.join(tmp_dir, "profiles.json")
    ssh_path = Path.join(tmp_dir, "ssh.db")

    store_name = :"test_cfg_store_#{System.unique_integer([:positive])}"
    ssh_store_name = :"test_ssh_store_#{System.unique_integer([:positive])}"

    {:ok, cfg_pid} =
      ConfigStore.start_link(name: store_name, config_path: cfg_path, json_path: json_path)

    {:ok, ssh_pid} = SSHProfileStore.start_link(name: ssh_store_name, config_path: ssh_path)

    ssh_prof = %SSHProfile{
      id: "ssh_persist",
      name: "Bastion",
      host: "10.0.0.2",
      port: 22,
      username: "ops"
    }

    conn_prof = %ConnectionProfile{
      id: "conn_persist",
      name: "DB",
      driver: :sqlite,
      database: ":memory:",
      ssh_profile_id: "ssh_persist"
    }

    assert :ok = SSHProfileStore.put_profile(ssh_store_name, ssh_prof)
    assert :ok = ConfigStore.put_profile(store_name, conn_prof)

    GenServer.stop(cfg_pid)
    GenServer.stop(ssh_pid)

    # Restart and verify ETS files reload persisted state
    store_name_2 = :"test_cfg_store_reload_#{System.unique_integer([:positive])}"
    ssh_store_name_2 = :"test_ssh_store_reload_#{System.unique_integer([:positive])}"

    {:ok, cfg_pid2} =
      ConfigStore.start_link(name: store_name_2, config_path: cfg_path, json_path: json_path)

    {:ok, ssh_pid2} = SSHProfileStore.start_link(name: ssh_store_name_2, config_path: ssh_path)

    assert ConfigStore.get_profile(store_name_2, "conn_persist") == conn_prof
    assert SSHProfileStore.get_profile(ssh_store_name_2, "ssh_persist") == ssh_prof

    # Unknown option keys are ignored instead of leaking atoms
    parsed =
      ConfigStore.profile_from_map(%{
        "id" => "x",
        "driver" => "postgres",
        "options" => %{"ssl" => true, "arbitrary_evil_key_xyz" => 1}
      })

    assert parsed.options == %{ssl: true}

    # Inline manual SSH config round-trips cleanly through profile_to_map / profile_from_map
    manual_prof = %ConnectionProfile{
      id: "conn_manual_ssh",
      name: "Manual SSH DB",
      driver: :postgres,
      host: "127.0.0.1",
      port: 5432,
      database: "prod",
      username: "pg",
      password: "pw",
      ssh: %{
        host: "bastion.example.com",
        port: 2222,
        username: "ops",
        password: "secret",
        identity_file: "~/.ssh/id_ed25519"
      }
    }

    roundtrip = manual_prof |> ConfigStore.profile_to_map() |> ConfigStore.profile_from_map()
    assert roundtrip.ssh == manual_prof.ssh
    assert roundtrip.ssh_profile_id == nil

    GenServer.stop(cfg_pid2)
    GenServer.stop(ssh_pid2)
  end

  test "auto-discovers ~/.ssh/config into SSHProfileStore without overwriting saved overrides" do
    tmp_dir =
      Path.join(System.tmp_dir!(), "strata_ssh_discover_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf(tmp_dir) end)

    ssh_db_path = Path.join(tmp_dir, "ssh.db")
    ssh_cfg_path = Path.join(tmp_dir, "ssh_config")

    File.write!(ssh_cfg_path, """
    # Global wildcard should be skipped
    Host *
      ServerAliveInterval 60

    Host prod-bastion
      HostName bastion.prod.internal
      User deploy # inline comment
      Port 2222
      IdentityFile "~/.ssh/prod_ed25519"

    Host db-direct.internal
      User postgres

    Host web-a web-b
      HostName 10.20.0.5
      User ubuntu

    Match host *.internal exec "true"
      User should_not_leak
    """)

    store_name = :"test_ssh_discover_#{System.unique_integer([:positive])}"

    {:ok, pid} =
      SSHProfileStore.start_link(
        name: store_name,
        config_path: ssh_db_path,
        ssh_config_paths: [ssh_cfg_path]
      )

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    profiles = SSHProfileStore.list_profiles(store_name)
    assert Enum.any?(profiles, &(&1.id == "prod-bastion"))
    assert Enum.any?(profiles, &(&1.id == "db-direct.internal"))
    assert Enum.any?(profiles, &(&1.id == "web-a"))
    assert Enum.any?(profiles, &(&1.id == "web-b"))
    refute Enum.any?(profiles, &(&1.id == "*"))

    prod = SSHProfileStore.get_profile(store_name, "prod-bastion")
    assert prod.host == "bastion.prod.internal"
    assert prod.username == "deploy"
    assert prod.port == 2222
    assert prod.identity_file == "~/.ssh/prod_ed25519"

    direct = SSHProfileStore.get_profile(store_name, "db-direct.internal")
    assert direct.host == "db-direct.internal"
    assert direct.username == "postgres"

    web_b = SSHProfileStore.get_profile(store_name, "web-b")
    assert web_b.host == "10.20.0.5"
    assert web_b.username == "ubuntu"

    # Saved overrides take precedence on reload
    edited = %{prod | port: 2200, password: "secret"}
    assert :ok = SSHProfileStore.put_profile(store_name, edited)
    GenServer.stop(pid)

    store_name_2 = :"test_ssh_discover_reload_#{System.unique_integer([:positive])}"

    {:ok, pid2} =
      SSHProfileStore.start_link(
        name: store_name_2,
        config_path: ssh_db_path,
        ssh_config_paths: [ssh_cfg_path]
      )

    on_exit(fn -> if Process.alive?(pid2), do: GenServer.stop(pid2) end)

    reloaded = SSHProfileStore.get_profile(store_name_2, "prod-bastion")
    assert reloaded.port == 2200
    assert reloaded.password == "secret"
  end

  test "SSHKeyCallback loads explicit custom IdentityFile path" do
    Application.ensure_all_started(:ssh)

    tmp_key =
      Path.join(System.tmp_dir!(), "strata_custom_key_#{System.unique_integer([:positive])}")

    {_, 0} = System.cmd("ssh-keygen", ["-t", "ed25519", "-N", "", "-f", tmp_key, "-q"])

    on_exit(fn ->
      File.rm(tmp_key)
      File.rm(tmp_key <> ".pub")
    end)

    assert {:ok, key} =
             Strata.SSHKeyCallback.user_key(:"ssh-ed25519",
               key_cb_private: [identity_file: tmp_key]
             )

    assert elem(key, 0) == :ECPrivateKey
  end
end
