defmodule Strata.UI.Components.ConnectionModal do
  @moduledoc """
  Modal form component for creating and editing Database Connection Profiles.
  Includes driver selection, host/port/db credentials, SSH profile selection,
  and [ Test Connection ] action with live status feedback.
  """

  alias Strata.ConnectionProfile

  @drivers [:postgres, :mysql, :sqlite]
  @fields [
    :name,
    :driver,
    :host,
    :port,
    :database,
    :username,
    :password,
    :ssl,
    :ssh_profile_id,
    :test_button,
    :save_button,
    :cancel_button
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
    ssh_profile_id: nil,
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
          ssh_profile_id: String.t() | nil,
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
          ssh_profile_id: profile.ssh_profile_id
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
          ssl: false
        }
      end

    opts_without_profile = Keyword.delete(opts, :profile)
    struct(base, opts_without_profile)
  end

  @doc """
  Converts modal form state to a Strata.ConnectionProfile struct.
  """
  def to_profile(%__MODULE__{} = modal) do
    name =
      cond do
        modal.name && String.trim(modal.name) != "" -> String.trim(modal.name)
        modal.database && String.trim(modal.database) != "" -> "#{String.upcase(to_string(modal.driver))} - #{modal.database}"
        true -> "#{String.upcase(to_string(modal.driver))} (#{modal.host})"
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
      ssh_profile_id: modal.ssh_profile_id,
      options: %{ssl: modal.ssl}
    }
  end

  @doc """
  Returns the visible ordered field keys for the given driver.
  """
  def visible_fields(:sqlite), do: [:name, :driver, :database, :test_button, :save_button, :cancel_button]
  def visible_fields(_driver), do: @fields

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
        ssl? = Map.get(query_map, "sslmode") in ["require", "verify-ca", "verify-full"] or Map.get(query_map, "ssl") == "true"

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
        name = if String.trim(updated.name || "") == "", do: Path.basename(updated.database || "") |> then(&if(&1 == "", do: "New Connection", else: &1)), else: updated.name
        %{updated | name: name, status_message: "⚡ Parsed #{String.upcase(to_string(updated.driver))} URI"}

      :error ->
        modal
    end
  end

  @doc """
  Handles key events for field navigation, dropdown cycling, toggle, and typing.
  """
  def handle_key(%__MODULE__{} = modal, :tab) do
    next_field = get_next_field(modal.driver, modal.focused_field, 1)
    %{modal | focused_field: next_field}
  end

  def handle_key(%__MODULE__{} = modal, :shift_tab) do
    prev_field = get_next_field(modal.driver, modal.focused_field, -1)
    %{modal | focused_field: prev_field}
  end

  def handle_key(%__MODULE__{} = modal, :down) do
    handle_key(modal, :tab)
  end

  def handle_key(%__MODULE__{} = modal, :up) do
    handle_key(modal, :shift_tab)
  end

  # Driver cycling with smart defaults
  def handle_key(%__MODULE__{focused_field: :driver} = modal, key) when key in [:right, :space, :enter] do
    cycle_driver(modal, 1)
  end

  def handle_key(%__MODULE__{focused_field: :driver} = modal, :left) do
    cycle_driver(modal, -1)
  end

  # SSL mode toggle
  def handle_key(%__MODULE__{focused_field: :ssl} = modal, key) when key in [:space, :enter, :right, :left] do
    %{modal | ssl: not modal.ssl}
  end

  # SSH profile selector cycling from SSHProfileStore
  def handle_key(%__MODULE__{focused_field: :ssh_profile_id} = modal, key)
      when key in [:right, :left, :space, :enter] do
    ids =
      try do
        [nil | Enum.map(Strata.SSHProfileStore.list_profiles(), & &1.id)]
      catch
        _, _ -> [nil]
      end

    idx = Enum.find_index(ids, &(&1 == modal.ssh_profile_id)) || 0
    delta = if key == :left, do: -1, else: 1
    next_id = Enum.at(ids, rem(idx + delta + length(ids), length(ids)))
    %{modal | ssh_profile_id: next_id}
  end

  # Global save shortcut inside modal
  def handle_key(%__MODULE__{} = modal, key) when key in [{:ctrl, "s"}, {:ctrl, "S"}] do
    {:save, modal}
  end

  # Pressing enter in text input fields advances to the next field safely
  def handle_key(%__MODULE__{focused_field: field} = modal, :enter)
      when field in [:name, :host, :port, :database, :username, :password] do
    handle_key(modal, :tab)
  end

  # Buttons handling
  def handle_key(%__MODULE__{focused_field: :test_button} = modal, key) when key in [:enter, :space] do
    test_connection(modal)
  end

  def handle_key(%__MODULE__{focused_field: :save_button} = modal, key) when key in [:enter, :space] do
    {:save, modal}
  end

  def handle_key(%__MODULE__{focused_field: :cancel_button} = modal, key) when key in [:enter, :space] do
    {:cancel, modal}
  end

  # Backspace handling (text fields only, never :ssh_profile_id)
  def handle_key(%__MODULE__{focused_field: field} = modal, :backspace)
      when field in [:name, :host, :port, :database, :username, :password] do
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

  # Text entry / URI paste handling (text fields only)
  def handle_key(%__MODULE__{focused_field: field} = modal, key)
      when is_binary(key) and field in [:name, :host, :port, :database, :username, :password] do
    if String.length(key) > 1 and parse_uri(key) != :error do
      apply_uri(modal, key)
    else
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
  end

  def handle_key(modal, _key), do: modal

  defp cycle_driver(modal, delta) do
    old_driver = modal.driver
    idx = Enum.find_index(@drivers, &(&1 == old_driver)) || 0
    next_driver = Enum.at(@drivers, rem(idx + delta + length(@drivers), length(@drivers)))

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

    %{modal | driver: next_driver, port: default_port(next_driver), database: new_db, username: new_user}
  end

  @doc """
  Executes connection test using supplied or default Strata.ConnectionWorker.test_connection/1.
  Updates `status` and `status_message`.
  """
  def test_connection(%__MODULE__{} = modal, test_fn \\ nil) do
    test_fn = test_fn || (&Strata.ConnectionWorker.test_connection/1)
    profile = to_profile(modal)

    case test_fn.(profile) do
      :ok ->
        %{modal | status: :ok, status_message: "⚡ Connection successful!"}

      {:ok, _} ->
        %{modal | status: :ok, status_message: "⚡ Connection successful!"}

      {:error, reason} ->
        msg = if is_binary(reason), do: reason, else: inspect(reason)
        %{modal | status: :error, status_message: "❌ Connection failed: " <> msg}
    end
  end

  @doc """
  Renders structured map representation of the modal for TUI rendering.
  """
  def render(%__MODULE__{} = modal, area) do
    ssh_display =
      case modal.ssh_profile_id do
        nil -> "(None — ←/→ to choose)"
        "" -> "(None — ←/→ to choose)"
        ssh_id ->
          case Strata.SSHProfileStore.get_profile(ssh_id) do
            %{name: sname} when is_binary(sname) and sname != "" -> "#{sname} (#{ssh_id})"
            _ -> ssh_id
          end
      end

    all_field_defs = %{
      name: %{label: "Name", key: :name, value: if(modal.name == "", do: "(Type Name or Paste URI...)", else: modal.name), type: :text},
      driver: %{
        label: "Driver",
        key: :driver,
        value: "#{Atom.to_string(modal.driver)} (←/→)",
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
      password: %{label: "Password", key: :password, value: String.duplicate("*", String.length(modal.password)), type: :password},
      ssl: %{label: "SSL Mode", key: :ssl, value: if(modal.ssl, do: "Enabled", else: "Disabled"), type: :toggle},
      ssh_profile_id: %{label: "SSH Profile", key: :ssh_profile_id, value: ssh_display, type: :select},
      test_button: %{label: "[⚡ Test Connection]", key: :test_button, type: :button},
      save_button: %{label: "[ Save (Ctrl+S) ]", key: :save_button, type: :button},
      cancel_button: %{label: "[ Cancel (Esc) ]", key: :cancel_button, type: :button}
    }

    fields = Enum.map(visible_fields(modal.driver), &Map.fetch!(all_field_defs, &1))

    %{
      title: "CONNECTION PROFILE (" <> String.upcase(Atom.to_string(modal.driver)) <> ")",
      area: area,
      focused_field: modal.focused_field,
      fields: fields,
      status: modal.status,
      status_message: modal.status_message
    }
  end

  defp get_next_field(driver, current, delta) do
    fields = visible_fields(driver)
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
