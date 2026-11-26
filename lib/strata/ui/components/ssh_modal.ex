defmodule Strata.UI.Components.SSHModal do
  @moduledoc """
  Modal form component for creating and editing SSH Tunnel Profiles.
  Supports SSH host/port configuration, password/private_key auth types,
  and [ Test SSH ] connection testing.
  """

  alias Strata.SSHProfile

  @auth_types [:password, :private_key]
  @fields [
    :profile_selector,
    :name,
    :host,
    :port,
    :username,
    :auth_type,
    :password,
    :identity_file,
    :passphrase,
    :test_button,
    :save_button,
    :delete_button,
    :cancel_button
  ]

  @doc """
  Returns the visible ordered fields for SSHModal. `:delete_button` is shown when editing a saved profile.
  """
  def visible_fields(%__MODULE__{id: id}) when is_binary(id) and id != "", do: @fields
  def visible_fields(_modal), do: List.delete(@fields, :delete_button)

  defstruct [
    :id,
    name: "New SSH Profile",
    host: "",
    port: 22,
    username: "",
    auth_type: :password,
    password: "",
    identity_file: "",
    passphrase: "",
    focused_field: :name,
    status: :idle,
    status_message: nil
  ]

  @type t :: %__MODULE__{
          id: String.t() | nil,
          name: String.t(),
          host: String.t(),
          port: integer(),
          username: String.t(),
          auth_type: :password | :private_key,
          password: String.t(),
          identity_file: String.t(),
          passphrase: String.t(),
          focused_field: atom(),
          status: :idle | :testing | :ok | :error,
          status_message: String.t() | nil
        }

  @doc """
  Initializes an SSHModal struct. Accepts keyword options or `:profile` with Strata.SSHProfile.
  """
  def new(opts \\ []) do
    profile = Keyword.get(opts, :profile)

    base =
      if profile do
        auth_type = if profile.identity_file && profile.identity_file != "", do: :private_key, else: :password

        %__MODULE__{
          id: profile.id,
          name: profile.name || "New SSH Profile",
          host: profile.host || "",
          port: profile.port || 22,
          username: profile.username || "",
          auth_type: auth_type,
          password: profile.password || "",
          identity_file: profile.identity_file || "",
          passphrase: profile.passphrase || ""
        }
      else
        %__MODULE__{}
      end

    opts_without_profile = Keyword.delete(opts, :profile)
    struct(base, opts_without_profile)
  end

  @doc """
  Converts modal form state into a Strata.SSHProfile struct.
  """
  def to_profile(%__MODULE__{} = modal) do
    %SSHProfile{
      id: modal.id || "ssh_" <> Integer.to_string(System.unique_integer([:positive])),
      name: modal.name,
      host: modal.host,
      port: modal.port,
      username: modal.username,
      password: if(modal.auth_type == :password, do: modal.password, else: nil),
      identity_file: if(modal.auth_type == :private_key, do: modal.identity_file, else: nil),
      passphrase: if(modal.auth_type == :private_key, do: modal.passphrase, else: nil)
    }
  end

  @doc """
  Handles key events for navigation, auth_type toggle, and field editing.
  """
  def handle_key(%__MODULE__{} = modal, :tab) do
    next_field = get_next_field(modal, modal.focused_field, 1)
    %{modal | focused_field: next_field}
  end

  def handle_key(%__MODULE__{} = modal, :shift_tab) do
    prev_field = get_next_field(modal, modal.focused_field, -1)
    %{modal | focused_field: prev_field}
  end

  def handle_key(%__MODULE__{} = modal, :down) do
    handle_key(modal, :tab)
  end

  def handle_key(%__MODULE__{} = modal, :up) do
    handle_key(modal, :shift_tab)
  end

  # Saved SSH profile selector cycling
  def handle_key(%__MODULE__{focused_field: :profile_selector} = modal, key)
      when key in [:right, :left, :space, :enter] do
    profiles =
      try do
        Strata.SSHProfileStore.list_profiles()
      catch
        _, _ -> []
      end

    options = [nil | profiles]
    idx = Enum.find_index(options, fn p -> (p && p.id) == modal.id end) || 0
    delta = if key == :left, do: -1, else: 1
    chosen = Enum.at(options, rem(idx + delta + length(options), length(options)))

    case chosen do
      nil ->
        %{new() | focused_field: :profile_selector}

      prof ->
        %{new(profile: prof) | focused_field: :profile_selector}
    end
  end

  # Auth type cycling
  def handle_key(%__MODULE__{focused_field: :auth_type} = modal, key)
      when key in [:space, :enter, :right, :left] do
    next_type = if modal.auth_type == :password, do: :private_key, else: :password
    %{modal | auth_type: next_type}
  end

  # Save shortcut & buttons
  def handle_key(%__MODULE__{} = modal, key) when key in [{:ctrl, "s"}, {:ctrl, "S"}] do
    {:save, modal}
  end

  def handle_key(%__MODULE__{focused_field: :test_button} = modal, key)
      when key in [:enter, :space] do
    test_ssh(modal)
  end

  def handle_key(%__MODULE__{focused_field: :save_button} = modal, key)
      when key in [:enter, :space] do
    {:save, modal}
  end

  def handle_key(%__MODULE__{focused_field: :delete_button, id: id} = modal, key)
      when is_binary(id) and key in [:enter, :space] do
    {:delete, modal}
  end

  def handle_key(%__MODULE__{focused_field: :cancel_button} = modal, key)
      when key in [:enter, :space] do
    {:cancel, modal}
  end

  def handle_key(%__MODULE__{focused_field: field} = modal, :enter)
      when field in [:name, :host, :port, :username, :password, :identity_file, :passphrase] do
    handle_key(modal, :tab)
  end

  # Backspace handling
  def handle_key(%__MODULE__{focused_field: field} = modal, :backspace)
      when field in [:name, :host, :port, :username, :password, :identity_file, :passphrase] do
    val = Map.get(modal, field)
    val_str = if is_integer(val), do: Integer.to_string(val), else: to_string(val || "")
    new_val_str = String.slice(val_str, 0, max(0, String.length(val_str) - 1))

    new_val =
      if field == :port do
        case Integer.parse(new_val_str) do
          {i, ""} -> i
          _ -> 0
        end
      else
        new_val_str
      end

    Map.put(modal, field, new_val)
  end

  # Text entry handling
  def handle_key(%__MODULE__{focused_field: field} = modal, key)
      when is_binary(key) and field in [:name, :host, :port, :username, :password, :identity_file, :passphrase] do
    val = Map.get(modal, field)

    if field == :port do
      val_str = Integer.to_string(val || 0) <> key

      case Integer.parse(val_str) do
        {i, ""} -> %{modal | port: i}
        _ -> modal
      end
    else
      val_str = (val || "") <> key
      Map.put(modal, field, val_str)
    end
  end

  def handle_key(modal, _key), do: modal

  @doc """
  Executes SSH connection test using test_fn or attempting SSHTunnel connect.
  Updates `status` and `status_message`.
  """
  def test_ssh(%__MODULE__{} = modal, test_fn \\ nil) do
    profile = to_profile(modal)

    test_fn =
      test_fn ||
        fn prof ->
          case Strata.SSHTunnel.connect(prof, "127.0.0.1", prof.port) do
            {:ok, _port, pid} ->
              Strata.SSHTunnel.stop(pid)
              :ok

            {:error, reason} ->
              {:error, reason}
          end
        end

    case test_fn.(profile) do
      :ok ->
        %{modal | status: :ok, status_message: "⚡ SSH connection successful!"}

      {:ok, _} ->
        %{modal | status: :ok, status_message: "⚡ SSH connection successful!"}

      {:error, reason} ->
        msg = if is_binary(reason), do: reason, else: inspect(reason)
        %{modal | status: :error, status_message: "❌ SSH test failed: " <> msg}
    end
  end

  @doc """
  Renders structured map representation of the modal for TUI rendering.
  """
  def render(%__MODULE__{} = modal, area) do
    selector_label =
      if is_binary(modal.id) and modal.id != "",
        do: "#{modal.name} (Editing · ←/→ to switch)",
        else: "(New SSH Profile · ←/→ to edit saved)"

    base_fields = [
      %{label: "Saved Profile", key: :profile_selector, value: selector_label, type: :select},
      %{label: "Name", key: :name, value: modal.name, type: :text},
      %{label: "Host", key: :host, value: modal.host, type: :text},
      %{label: "Port", key: :port, value: Integer.to_string(modal.port), type: :text},
      %{label: "Username", key: :username, value: modal.username, type: :text},
      %{label: "Auth Type", key: :auth_type, value: Atom.to_string(modal.auth_type), type: :select, options: Enum.map(@auth_types, &Atom.to_string/1)},
      %{label: "Password", key: :password, value: String.duplicate("*", String.length(modal.password)), type: :password},
      %{label: "Private Key Path", key: :identity_file, value: modal.identity_file, type: :text},
      %{label: "Passphrase", key: :passphrase, value: String.duplicate("*", String.length(modal.passphrase)), type: :password},
      %{label: "[⚡ Test SSH]", key: :test_button, type: :button},
      %{label: "[ Save (Ctrl+S) ]", key: :save_button, type: :button}
    ]

    delete_field =
      if is_binary(modal.id) and modal.id != "",
        do: [%{label: "[🗑 Delete SSH]", key: :delete_button, type: :button}],
        else: []

    fields = base_fields ++ delete_field ++ [%{label: "[ Cancel (Esc) ]", key: :cancel_button, type: :button}]

    %{
      title: "SSH PROFILE SETUP",
      area: area,
      focused_field: modal.focused_field,
      fields: fields,
      status: modal.status,
      status_message: modal.status_message
    }
  end

  defp get_next_field(modal, current, delta) do
    fields = visible_fields(modal)
    idx = Enum.find_index(fields, &(&1 == current)) || 0
    cnt = length(fields)
    Enum.at(fields, rem(idx + delta + cnt, cnt))
  end
end
