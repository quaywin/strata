defmodule DBData.ConfigStoreTest do
  use ExUnit.Case

  alias DBData.{ConfigStore, ConnectionProfile, SSHProfileStore, SSHProfile}

  test "stores and retrieves DB connection and SSH profiles" do
    ssh_prof = %SSHProfile{id: "ssh1", name: "My Server", host: "1.2.3.4", port: 22, username: "root"}
    assert :ok = SSHProfileStore.put_profile(ssh_prof)
    assert SSHProfileStore.get_profile("ssh1") == ssh_prof
    assert ssh_prof in SSHProfileStore.list_profiles()

    conn_prof = %ConnectionProfile{id: "conn1", name: "Prod PG", driver: :postgres, host: "localhost", port: 5432, ssh_profile_id: "ssh1"}
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
end
