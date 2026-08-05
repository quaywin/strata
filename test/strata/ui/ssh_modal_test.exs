defmodule Strata.UI.Components.SSHModalTest do
  use ExUnit.Case, async: true
  alias Strata.UI.Components.SSHModal
  alias Strata.SSHProfile

  describe "new/1 & to_profile/1" do
    test "initializes default ssh modal state" do
      modal = SSHModal.new()
      assert modal.port == 22
      assert modal.auth_type == :password
      assert modal.focused_field == :name
      assert modal.status == :idle
    end

    test "initializes from existing SSHProfile struct" do
      profile = %SSHProfile{
        id: "prod_ssh",
        name: "Prod SSH",
        host: "bastion.example.com",
        port: 2222,
        username: "ec2-user",
        identity_file: "~/.ssh/id_ed25519"
      }

      modal = SSHModal.new(profile: profile)
      assert modal.id == "prod_ssh"
      assert modal.name == "Prod SSH"
      assert modal.host == "bastion.example.com"
      assert modal.port == 2222
      assert modal.username == "ec2-user"
      assert modal.auth_type == :private_key
      assert modal.identity_file == "~/.ssh/id_ed25519"
    end

    test "to_profile converts modal state to SSHProfile" do
      modal = SSHModal.new(
        name: "AWS Bastion",
        host: "1.2.3.4",
        port: 22,
        username: "ubuntu",
        auth_type: :private_key,
        identity_file: "/home/ubuntu/.ssh/id_rsa"
      )

      profile = SSHModal.to_profile(modal)
      assert profile.name == "AWS Bastion"
      assert profile.host == "1.2.3.4"
      assert profile.port == 22
      assert profile.username == "ubuntu"
      assert profile.identity_file == "/home/ubuntu/.ssh/id_rsa"
    end
  end

  describe "handle_key/2 field navigation and input" do
    test "navigates focused fields with tab and shift_tab" do
      modal = SSHModal.new()
      assert modal.focused_field == :name

      modal = SSHModal.handle_key(modal, :tab)
      assert modal.focused_field == :host

      modal = SSHModal.handle_key(modal, :tab)
      assert modal.focused_field == :port

      modal = SSHModal.handle_key(modal, :shift_tab)
      assert modal.focused_field == :host
    end

    test "toggles auth_type when auth_type field is focused" do
      modal = SSHModal.new(auth_type: :password)
      modal = %{modal | focused_field: :auth_type}

      modal = SSHModal.handle_key(modal, :space)
      assert modal.auth_type == :private_key

      modal = SSHModal.handle_key(modal, :space)
      assert modal.auth_type == :password
    end

    test "types text into focused input field" do
      modal = SSHModal.new(host: "bastion", focused_field: :host)

      modal = SSHModal.handle_key(modal, ".io")
      assert modal.host == "bastion.io"

      modal = SSHModal.handle_key(modal, :backspace)
      assert modal.host == "bastion.i"
    end
  end

  describe "test_ssh/2" do
    test "updates status to ok on successful test_fn call" do
      modal = SSHModal.new(host: "1.2.3.4")

      test_fn = fn _profile -> :ok end
      modal = SSHModal.test_ssh(modal, test_fn)

      assert modal.status == :ok
      assert modal.status_message =~ "SSH connection successful"
    end

    test "updates status to error on failed test_fn call" do
      modal = SSHModal.new(host: "invalid")

      test_fn = fn _profile -> {:error, "Host unreachable"} end
      modal = SSHModal.test_ssh(modal, test_fn)

      assert modal.status == :error
      assert modal.status_message =~ "Host unreachable"
    end
  end

  describe "render/2" do
    test "returns structured map containing title and fields" do
      modal = SSHModal.new(name: "Prod Bastion")
      rendered = SSHModal.render(modal, %{width: 60, height: 20})

      assert rendered.title =~ "SSH PROFILE"
      assert is_list(rendered.fields)
      assert rendered.focused_field == :name
    end
  end
end
