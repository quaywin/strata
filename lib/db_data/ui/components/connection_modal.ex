defmodule DBData.UI.Components.ConnectionModal do
  @moduledoc """
  Modal form component for creating and editing Database Connection Profiles.
  Includes driver selection, host/port/db credentials, SSH profile selection,
  and [ Test Connection ] action with live status feedback.
  """

  alias DBData.ConnectionProfile

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
  Converts modal form state to a DBData.ConnectionProfile struct.
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
  Handles key events for field navigation, dropdown cycling, toggle, and typing.
  """
  def handle_key(%__MODULE__{} = modal, :tab) do
    next_field = get_next_field(modal.focused_field, 1)
    %{modal | focused_field: next_field}
  end

  def handle_key(%__MODULE__{} = modal, :shift_tab) do
    prev_field = get_next_field(modal.focused_field, -1)
    %{modal | focused_field: prev_field}
  end

  def handle_key(%__MODULE__{} = modal, :down) do
    handle_key(modal, :tab)
  end

  def handle_key(%__MODULE__{} = modal, :up) do
    handle_key(modal, :shift_tab)
  end

  # Driver cycling
  def handle_key(%__MODULE__{focused_field: :driver} = modal, key) when key in [:right, :space, :enter] do
    idx = Enum.find_index(@drivers, &(&1 == modal.driver)) || 0
    next_driver = Enum.at(@drivers, rem(idx + 1, length(@drivers)))
    port = default_port(next_driver)
    %{modal | driver: next_driver, port: port}
  end

  def handle_key(%__MODULE__{focused_field: :driver} = modal, key) when key in [:left] do
    idx = Enum.find_index(@drivers, &(&1 == modal.driver)) || 0
    prev_driver = Enum.at(@drivers, rem(idx - 1 + length(@drivers), length(@drivers)))
    port = default_port(prev_driver)
    %{modal | driver: prev_driver, port: port}
  end

  # SSL mode toggle
  def handle_key(%__MODULE__{focused_field: :ssl} = modal, key) when key in [:space, :enter, :right, :left] do
    %{modal | ssl: not modal.ssl}
  end

  # Global save shortcut inside modal
  def handle_key(%__MODULE__{} = modal, key) when key in [{:ctrl, "s"}, {:ctrl, "S"}] do
    {:save, modal}
  end

  # Pressing enter in text input fields directly submits/saves the modal form
  def handle_key(%__MODULE__{focused_field: field} = modal, :enter)
      when field in [:name, :host, :port, :database, :username, :password, :ssh_profile_id] do
    {:save, modal}
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

  # Backspace handling
  def handle_key(%__MODULE__{focused_field: field} = modal, :backspace)
      when field in [:name, :host, :port, :database, :username, :password, :ssh_profile_id] do
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
      when is_binary(key) and field in [:name, :host, :port, :database, :username, :password, :ssh_profile_id] do
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
  Executes connection test using supplied or default DBData.ConnectionWorker.test_connection/1.
  Updates `status` and `status_message`.
  """
  def test_connection(%__MODULE__{} = modal, test_fn \\ nil) do
    test_fn = test_fn || (&DBData.ConnectionWorker.test_connection/1)
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
    fields = [
      %{label: "Name", key: :name, value: if(modal.name == "", do: "(Type Name...)", else: modal.name), type: :text},
      %{
        label: "Driver",
        key: :driver,
        value: Atom.to_string(modal.driver),
        type: :select,
        options: Enum.map(@drivers, &Atom.to_string/1)
      },
      %{label: "Host", key: :host, value: modal.host, type: :text},
      %{label: "Port", key: :port, value: Integer.to_string(modal.port), type: :text},
      %{label: "Database", key: :database, value: modal.database, type: :text},
      %{label: "Username", key: :username, value: modal.username, type: :text},
      %{label: "Password", key: :password, value: String.duplicate("*", String.length(modal.password)), type: :password},
      %{label: "SSL Mode", key: :ssl, value: if(modal.ssl, do: "Enabled", else: "Disabled"), type: :toggle},
      %{label: "SSH Profile", key: :ssh_profile_id, value: modal.ssh_profile_id || "(None)", type: :text},
      %{label: "[⚡ Test Connection]", key: :test_button, type: :button},
      %{label: "[ Save ]", key: :save_button, type: :button},
      %{label: "[ Cancel ]", key: :cancel_button, type: :button}
    ]

    %{
      title: "CONNECTION PROFILE (" <> String.upcase(Atom.to_string(modal.driver)) <> ")",
      area: area,
      focused_field: modal.focused_field,
      fields: fields,
      status: modal.status,
      status_message: modal.status_message
    }
  end

  defp get_next_field(current, delta) do
    idx = Enum.find_index(@fields, &(&1 == current)) || 0
    cnt = length(@fields)
    Enum.at(@fields, rem(idx + delta + cnt, cnt))
  end

  defp default_port(driver) do
    DBData.Adapter.default_port(driver)
  end
end
