defmodule Strata.UI.Components.ConnectionModal do
  @moduledoc """
  Modal form component for creating and editing Database Connection Profiles.
  Includes driver selection, host/port/db credentials, SSH profile selection,
  and [ Test Connection ] action with live status feedback.
  """

  alias Strata.ConnectionProfile

  @drivers [:postgres, :mysql, :sqlite]
  @base_fields [
    :name,
    :driver,
    :host,
    :port,
    :database,
    :username,
    :password,
    :ssl,
    :auto_connect,
    :ssh_profile_id
  ]
  @manual_ssh_fields [
    :ssh_host,
    :ssh_port,
    :ssh_username,
    :ssh_password,
    :ssh_identity_file
  ]
  @button_fields [
    :test_button,
    :save_button,
    :cancel_button
  ]
  @text_fields [
    :name,
    :host,
    :port,
    :database,
    :username,
    :password,
    :ssh_host,
    :ssh_port,
    :ssh_username,
    :ssh_password,
    :ssh_identity_file
  ]

  defstruct [
    :id,
    name: "New Connection",
    driver: :postgres,
    host: "localhost",
    port: 5432,
    database: "postgres",
    username: "postgres",
    password: "",
    ssl: false,
    auto_connect: false,
    ssh_mode: :none,
    ssh_profile_id: nil,
    ssh_host: "",
    ssh_port: 22,
    ssh_username: "",
    ssh_password: "",
    ssh_identity_file: "",
    focused_field: :name,
    status: :idle,
    status_message: nil
  ]

  @type t :: %__MODULE__{
          id: String.t() | nil,
          name: String.t(),
          driver: atom(),
          host: String.t(),
          port: integer(),
          database: String.t(),
          username: String.t(),
          password: String.t(),
          ssl: boolean(),
          auto_connect: boolean(),
          ssh_mode: :none | :profile | :manual,
          ssh_profile_id: String.t() | nil,
          ssh_host: String.t(),
          ssh_port: integer(),
          ssh_username: String.t(),
          ssh_password: String.t(),
          ssh_identity_file: String.t(),
          focused_field: atom(),
          status: :idle | :testing | :ok | :error,
          status_message: String.t() | nil
        }

  @doc """
  Initializes a new ConnectionModal struct.
  Accepts keyword options or `:profile` with an existing ConnectionProfile.
  """
  def new(opts \\ []) do
    profile = Keyword.get(opts, :profile)

    base =
      if profile do
        ssh_map = Map.get(profile, :ssh)

        {ssh_mode, ssh_id, ssh_host, ssh_port, ssh_user, ssh_pass, ssh_key} =
          cond do
            is_map(ssh_map) and to_string(Map.get(ssh_map, :host) || "") |> String.trim() != "" ->
              {
                :manual,
                nil,
                Map.get(ssh_map, :host, ""),
                Map.get(ssh_map, :port) || 22,
                Map.get(ssh_map, :username) || "",
                Map.get(ssh_map, :password) || "",
                Map.get(ssh_map, :identity_file) || ""
              }

            is_binary(profile.ssh_profile_id) and profile.ssh_profile_id != "" ->
              {:profile, profile.ssh_profile_id, "", 22, "", "", ""}

            true ->
              {:none, nil, "", 22, "", "", ""}
          end

        %__MODULE__{
          id: profile.id,
          name: profile.name || "",
          driver: profile.driver || :postgres,
          host: profile.host || "localhost",
          port: profile.port || default_port(profile.driver),
          database: profile.database || "",
          username: profile.username || "",
          password: profile.password || "",
          ssl: Map.get(profile.options || %{}, :ssl, false),
          auto_connect: Map.get(profile, :auto_connect, false) == true,
          ssh_mode: ssh_mode,
          ssh_profile_id: ssh_id,
          ssh_host: ssh_host,
          ssh_port: ssh_port,
          ssh_username: ssh_user,
          ssh_password: ssh_pass,
          ssh_identity_file: ssh_key
        }
      else
        %__MODULE__{
          name: "",
          driver: :postgres,
          host: "localhost",
          port: 5432,
          database: "postgres",
          username: "postgres",
          password: "",
          ssl: false,
          auto_connect: false
        }
      end

    opts_without_profile = Keyword.delete(opts, :profile)
    modal = struct(base, opts_without_profile)

    cond do
      Keyword.has_key?(opts_without_profile, :ssh_mode) ->
        modal

      is_binary(modal.ssh_profile_id) and modal.ssh_profile_id != "" ->
        %{modal | ssh_mode: :profile}

      String.trim(modal.ssh_host || "") != "" ->
        %{modal | ssh_mode: :manual}

      true ->
        modal
    end
  end

  @doc """
  Converts modal form state to a Strata.ConnectionProfile struct.
  """
  def to_profile(%__MODULE__{} = modal) do
    name =
      cond do
        modal.name && String.trim(modal.name) != "" ->
          String.trim(modal.name)

        modal.database && String.trim(modal.database) != "" ->
          "#{String.upcase(to_string(modal.driver))} - #{modal.database}"

        true ->
          "#{String.upcase(to_string(modal.driver))} (#{modal.host})"
      end

    {ssh_profile_id, ssh} =
      case modal.ssh_mode do
        :manual ->
          ssh_host = String.trim(modal.ssh_host || "")

          if ssh_host != "" do
            {nil,
             %{
               host: ssh_host,
               port: modal.ssh_port || 22,
               username: String.trim(modal.ssh_username || ""),
               password: modal.ssh_password || "",
               identity_file: String.trim(modal.ssh_identity_file || "")
             }}
          else
            {nil, nil}
          end

        :profile when is_binary(modal.ssh_profile_id) and modal.ssh_profile_id != "" ->
          {modal.ssh_profile_id, nil}

        _ ->
          if is_binary(modal.ssh_profile_id) and modal.ssh_profile_id != "" do
            {modal.ssh_profile_id, nil}
          else
            {nil, nil}
          end
      end

    %ConnectionProfile{
      id: modal.id || "conn_" <> Integer.to_string(System.unique_integer([:positive])),
      name: name,
      driver: modal.driver,
      host: modal.host,
      port: modal.port,
      database: modal.database,
      username: modal.username,
      password: modal.password,
      ssh_profile_id: ssh_profile_id,
      ssh: ssh,
      auto_connect: modal.auto_connect == true,
      options: %{ssl: modal.ssl}
    }
  end

  @doc """
  Returns the visible ordered field keys for the given driver or `ConnectionModal` struct.
  """
  def visible_fields(%__MODULE__{driver: :sqlite}),
    do: [:name, :driver, :database, :auto_connect] ++ @button_fields

  def visible_fields(%__MODULE__{ssh_mode: :manual}),
    do: @base_fields ++ @manual_ssh_fields ++ @button_fields

  def visible_fields(%__MODULE__{}),
    do: @base_fields ++ @button_fields

  def visible_fields(:sqlite),
    do: [:name, :driver, :database, :auto_connect] ++ @button_fields

  def visible_fields(_driver),
    do: @base_fields ++ @button_fields

  @doc """
  Parses a database URI (`postgres://...`, `mysql://...`) or SQLite file path into field attributes.
  Returns `{:ok, attrs}` or `:error`.
  """
  def parse_uri(input) when is_binary(input) do
    trimmed = String.trim(input)

    cond do
      String.starts_with?(trimmed, ["postgres://", "postgresql://", "mysql://"]) ->
        uri = URI.parse(trimmed)
        driver = if String.starts_with?(trimmed, "mysql://"), do: :mysql, else: :postgres
        port = uri.port || default_port(driver)
        host = if is_binary(uri.host) and uri.host != "", do: uri.host, else: "localhost"
        db = uri.path |> to_string() |> String.trim_leading("/")

        {user, pass} =
          case uri.userinfo do
            nil ->
              {default_username(driver), ""}

            info ->
              case String.split(info, ":", parts: 2) do
                [u, p] -> {URI.decode(u), URI.decode(p)}
                [u] -> {URI.decode(u), ""}
              end
          end

        query_map = if is_binary(uri.query), do: URI.decode_query(uri.query), else: %{}

        ssl? =
          Map.get(query_map, "sslmode") in ["require", "verify-ca", "verify-full"] or
            Map.get(query_map, "ssl") == "true"

        {:ok,
         %{
           driver: driver,
           host: host,
           port: port,
           database: db,
           username: user,
           password: pass,
           ssl: ssl?
         }}

      Regex.match?(~r/\.(db|sqlite|sqlite3)$/i, trimmed) or trimmed == ":memory:" ->
        {:ok, %{driver: :sqlite, port: 0, database: trimmed}}

      true ->
        :error
    end
  end

  def parse_uri(_), do: :error

  @doc """
  Applies a parsed connection URI or SQLite file path onto the modal state if valid.
  """
  def apply_uri(%__MODULE__{} = modal, input) when is_binary(input) do
    case parse_uri(input) do
      {:ok, attrs} ->
        updated = struct(modal, attrs)

        name =
          if String.trim(updated.name || "") == "",
            do:
              Path.basename(updated.database || "")
              |> then(&if(&1 == "", do: "New Connection", else: &1)),
            else: updated.name

        %{
          updated
          | name: name,
            status_message: "⚡ Parsed #{String.upcase(to_string(updated.driver))} URI"
        }

      :error ->
        modal
    end
  end

  @doc """
  Handles key events for field navigation, dropdown cycling, toggle, and typing.
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

  # Driver cycling with smart defaults
  def handle_key(%__MODULE__{focused_field: :driver} = modal, key)
      when key in [:right, :space, :enter] do
    cycle_driver(modal, 1)
  end

  def handle_key(%__MODULE__{focused_field: :driver} = modal, :left) do
    cycle_driver(modal, -1)
  end

  # SSL mode toggle
  def handle_key(%__MODULE__{focused_field: :ssl} = modal, key)
      when key in [:space, :enter, :right, :left] do
    %{modal | ssl: not modal.ssl}
  end

  # Auto-connect on startup toggle
  def handle_key(%__MODULE__{focused_field: :auto_connect} = modal, key)
      when key in [:space, :enter, :right, :left] do
    %{modal | auto_connect: not modal.auto_connect}
  end

  # SSH tunnel cycling: (None) -> Manual -> ~/.ssh/config profiles
  def handle_key(%__MODULE__{focused_field: :ssh_profile_id} = modal, key)
      when key in [:right, :left, :space, :enter] do
    options = modal |> dropdown_options(:ssh_profile_id) |> Enum.map(& &1.value)
    current = current_ssh_option(modal)

    idx = Enum.find_index(options, &(&1 == current)) || 0
    delta = if key == :left, do: -1, else: 1
    next = Enum.at(options, rem(idx + delta + length(options), length(options)))
    apply_ssh_selection(modal, next)
  end

  # Global save shortcut inside modal
  def handle_key(%__MODULE__{} = modal, key) when key in [{:ctrl, "s"}, {:ctrl, "S"}] do
    {:save, modal}
  end

  # Pressing enter in text input fields advances to the next field safely
  def handle_key(%__MODULE__{focused_field: field} = modal, :enter)
      when field in @text_fields do
    handle_key(modal, :tab)
  end

  def handle_key(%__MODULE__{focused_field: field} = modal, :right)
      when field in [:test_button, :save_button, :cancel_button] do
    handle_key(modal, :tab)
  end

  def handle_key(%__MODULE__{focused_field: field} = modal, :left)
      when field in [:test_button, :save_button, :cancel_button] do
    handle_key(modal, :shift_tab)
  end

  # Buttons handling
  def handle_key(%__MODULE__{focused_field: :test_button} = modal, key)
      when key in [:enter, :space] do
    test_connection(modal)
  end

  def handle_key(%__MODULE__{focused_field: :save_button} = modal, key)
      when key in [:enter, :space] do
    {:save, modal}
  end

  def handle_key(%__MODULE__{focused_field: :cancel_button} = modal, key)
      when key in [:enter, :space] do
    {:cancel, modal}
  end

  # Backspace handling (text fields only, never :ssh_profile_id)
  def handle_key(%__MODULE__{focused_field: field} = modal, :backspace)
      when field in @text_fields do
    val = Map.get(modal, field)
    val_str = if is_integer(val), do: Integer.to_string(val), else: to_string(val || "")
    new_val_str = String.slice(val_str, 0, max(0, String.length(val_str) - 1))

    new_val =
      if field in [:port, :ssh_port] do
        case Integer.parse(new_val_str) do
          {i, ""} -> i
          _ -> 0
        end
      else
        new_val_str
      end

    Map.put(modal, field, new_val)
  end

  # Text entry / URI paste handling (text fields only)
  def handle_key(%__MODULE__{focused_field: field} = modal, key)
      when is_binary(key) and field in @text_fields do
    if field in [:name, :host, :database] and String.length(key) > 1 and parse_uri(key) != :error do
      apply_uri(modal, key)
    else
      val = Map.get(modal, field)

      if field in [:port, :ssh_port] do
        val_str = Integer.to_string(val || 0) <> key

        case Integer.parse(val_str) do
          {i, ""} -> Map.put(modal, field, i)
          _ -> modal
        end
      else
        val_str = (val || "") <> key
        Map.put(modal, field, val_str)
      end
    end
  end

  def handle_key(modal, _key), do: modal

  defp cycle_driver(modal, delta) do
    old_driver = modal.driver
    idx = Enum.find_index(@drivers, &(&1 == old_driver)) || 0
    next_driver = Enum.at(@drivers, rem(idx + delta + length(@drivers), length(@drivers)))
    apply_driver(modal, next_driver)
  end

  defp apply_driver(modal, next_driver) do
    old_driver = modal.driver

    new_db =
      if modal.database in [default_database(old_driver), ""] do
        default_database(next_driver)
      else
        modal.database
      end

    new_user =
      if modal.username in [default_username(old_driver), ""] do
        default_username(next_driver)
      else
        modal.username
      end

    %{
      modal
      | driver: next_driver,
        port: default_port(next_driver),
        database: new_db,
        username: new_user
    }
  end

  @doc """
  Returns dropdown options `[%{value, label, selected?}]` for a `:select` field.
  """
  @spec dropdown_options(t(), atom()) :: [map()]
  def dropdown_options(%__MODULE__{} = modal, :driver) do
    Enum.map(@drivers, fn drv ->
      %{value: drv, label: Atom.to_string(drv), selected?: drv == modal.driver}
    end)
  end

  def dropdown_options(%__MODULE__{} = modal, :ssh_profile_id) do
    current = current_ssh_option(modal)
    profiles = list_ssh_profiles()

    none_opt = %{value: :none, label: "(None)", selected?: current == :none}

    profile_opts =
      Enum.map(profiles, fn profile ->
        value = {:profile, profile.id}

        %{
          value: value,
          label: format_ssh_profile_label(profile, profile.id),
          selected?: current == value
        }
      end)

    manual_opt = %{
      value: :manual,
      label: "Manual (Enter SSH below)",
      selected?: current == :manual
    }

    [none_opt, manual_opt | profile_opts]
  end

  def dropdown_options(_modal, _field), do: []

  @doc """
  Applies a chosen dropdown value to a `:select` field.
  """
  @spec apply_dropdown_selection(t(), atom(), term()) :: t()
  def apply_dropdown_selection(%__MODULE__{} = modal, :driver, driver)
      when driver in @drivers do
    apply_driver(modal, driver)
  end

  def apply_dropdown_selection(%__MODULE__{} = modal, :ssh_profile_id, selection) do
    apply_ssh_selection(modal, selection)
  end

  def apply_dropdown_selection(modal, _field, _value), do: modal

  defp current_ssh_option(%__MODULE__{} = modal) do
    case modal.ssh_mode do
      :manual -> :manual
      :profile when is_binary(modal.ssh_profile_id) -> {:profile, modal.ssh_profile_id}
      _ -> :none
    end
  end

  defp apply_ssh_selection(modal, :none), do: %{modal | ssh_mode: :none, ssh_profile_id: nil}

  defp apply_ssh_selection(modal, {:profile, id}) when is_binary(id),
    do: %{modal | ssh_mode: :profile, ssh_profile_id: id}

  defp apply_ssh_selection(modal, :manual), do: %{modal | ssh_mode: :manual, ssh_profile_id: nil}
  defp apply_ssh_selection(modal, _other), do: modal

  defp list_ssh_profiles do
    try do
      Strata.SSHProfileStore.list_profiles()
    catch
      _, _ -> []
    end
  end

  defp format_ssh_profile_label(
         %{name: sname, username: suser, host: shost},
         _fallback_id
       )
       when is_binary(sname) and sname != "" and is_binary(shost) and shost != "" do
    user_part = if is_binary(suser) and suser != "", do: "#{suser}@", else: ""
    "#{sname} (#{user_part}#{shost})"
  end

  defp format_ssh_profile_label(%{name: sname}, fallback_id)
       when is_binary(sname) and sname != "" do
    "#{sname} (#{fallback_id})"
  end

  defp format_ssh_profile_label(_profile, fallback_id), do: to_string(fallback_id || "")

  @doc """
  Executes connection test using supplied or default Strata.ConnectionWorker.test_connection/1.
  Updates `status` and `status_message`.
  """
  def test_connection(%__MODULE__{} = modal, test_fn \\ nil) do
    test_fn = test_fn || (&Strata.ConnectionWorker.test_connection/1)
    profile = to_profile(modal)
    apply_test_result(modal, test_fn.(profile))
  end

  @doc """
  Applies a connection test result (`:ok`, `{:ok, _}`, or `{:error, reason}`) onto the modal.
  """
  @spec apply_test_result(t(), :ok | {:ok, term()} | {:error, term()}) :: t()
  def apply_test_result(%__MODULE__{} = modal, :ok) do
    %{modal | status: :ok, status_message: "⚡ Connection successful!"}
  end

  def apply_test_result(%__MODULE__{} = modal, {:ok, _}) do
    %{modal | status: :ok, status_message: "⚡ Connection successful!"}
  end

  def apply_test_result(%__MODULE__{} = modal, {:error, reason}) do
    msg = Strata.Formatter.format_error(reason)
    %{modal | status: :error, status_message: "❌ Connection failed: " <> msg}
  end

  @doc """
  Renders structured map representation of the modal for TUI rendering.
  """
  def render(%__MODULE__{} = modal, area) do
    ssh_display =
      case modal.ssh_mode do
        :manual ->
          "Manual (Enter SSH below)"

        :profile when is_binary(modal.ssh_profile_id) and modal.ssh_profile_id != "" ->
          modal.ssh_profile_id
          |> Strata.SSHProfileStore.get_profile()
          |> format_ssh_profile_label(modal.ssh_profile_id)

        _ ->
          "(None)"
      end

    all_field_defs = %{
      name: %{
        label: "Name",
        key: :name,
        value: if(modal.name == "", do: "(Type Name or Paste URI...)", else: modal.name),
        type: :text
      },
      driver: %{
        label: "Driver",
        key: :driver,
        value: Atom.to_string(modal.driver),
        type: :select,
        options: Enum.map(@drivers, &Atom.to_string/1)
      },
      host: %{label: "Host", key: :host, value: modal.host, type: :text},
      port: %{label: "Port", key: :port, value: Integer.to_string(modal.port), type: :text},
      database: %{
        label: if(modal.driver == :sqlite, do: "DB File Path", else: "Database"),
        key: :database,
        value: modal.database,
        type: :text
      },
      username: %{label: "Username", key: :username, value: modal.username, type: :text},
      password: %{
        label: "Password",
        key: :password,
        value: String.duplicate("*", String.length(modal.password)),
        type: :password
      },
      ssl: %{
        label: "SSL Mode",
        key: :ssl,
        value: if(modal.ssl, do: "Enabled", else: "Disabled"),
        type: :toggle
      },
      auto_connect: %{
        label: "Auto-Connect",
        key: :auto_connect,
        value: if(modal.auto_connect, do: "Enabled (On Startup)", else: "Disabled (Manual)"),
        type: :toggle
      },
      ssh_profile_id: %{
        label: "SSH Tunnel",
        key: :ssh_profile_id,
        value: ssh_display,
        type: :select
      },
      ssh_host: %{label: "SSH Host", key: :ssh_host, value: modal.ssh_host, type: :text},
      ssh_port: %{
        label: "SSH Port",
        key: :ssh_port,
        value: Integer.to_string(modal.ssh_port || 22),
        type: :text
      },
      ssh_username: %{
        label: "SSH User",
        key: :ssh_username,
        value: modal.ssh_username,
        type: :text
      },
      ssh_password: %{
        label: "SSH Password",
        key: :ssh_password,
        value: String.duplicate("*", String.length(modal.ssh_password || "")),
        type: :password
      },
      ssh_identity_file: %{
        label: "SSH Key Path",
        key: :ssh_identity_file,
        value:
          if(modal.ssh_identity_file == "",
            do: "(Optional, e.g. ~/.ssh/id_ed25519)",
            else: modal.ssh_identity_file
          ),
        type: :text
      },
      test_button: %{label: "[⚡ Test Connection]", key: :test_button, type: :button},
      save_button: %{label: "[ Save (Ctrl+S) ]", key: :save_button, type: :button},
      cancel_button: %{label: "[ Cancel (Esc) ]", key: :cancel_button, type: :button}
    }

    fields = Enum.map(visible_fields(modal), &Map.fetch!(all_field_defs, &1))

    %{
      title: "CONNECTION PROFILE (" <> String.upcase(Atom.to_string(modal.driver)) <> ")",
      area: area,
      focused_field: modal.focused_field,
      fields: fields,
      status: modal.status,
      status_message: modal.status_message
    }
  end

  defp get_next_field(modal_or_driver, current, delta) do
    fields = visible_fields(modal_or_driver)
    idx = Enum.find_index(fields, &(&1 == current)) || 0
    cnt = length(fields)
    Enum.at(fields, rem(idx + delta + cnt, cnt))
  end

  defp default_port(driver) do
    Strata.Adapter.default_port(driver)
  end

  defp default_database(:postgres), do: "postgres"
  defp default_database(_), do: ""

  defp default_username(:postgres), do: "postgres"
  defp default_username(:mysql), do: "root"
  defp default_username(_), do: ""
end
