defmodule Strata.Adapter do
  @moduledoc """
  Behaviour specification for database adapters (Postgres, MySQL, SQLite, etc.).
  Defines standard contracts for connection management, query execution, and schema inspection.
  """

  alias Strata.ConnectionProfile

  @type conn :: term()

  @callback default_port() :: pos_integer()
  @callback probe_query() :: String.t()
  @callback connect(profile :: ConnectionProfile.t(), host :: String.t(), port :: integer()) ::
              {:ok, conn()} | {:error, term()}
  @callback execute_query(conn :: conn(), sql :: String.t(), params :: list()) ::
              {:ok, %{columns: [String.t()], rows: [list()]}} | {:error, term()}
  @callback list_schemas(conn :: conn()) :: [String.t()]
  @callback list_tables(conn :: conn(), schema :: String.t()) :: [String.t()]
  @callback close(conn :: conn()) :: :ok

  @doc """
  Returns list of all supported driver atoms.
  """
  @spec supported_drivers() :: [atom()]
  def supported_drivers do
    [:postgres, :mysql, :sqlite]
  end

  @doc """
  Maps driver atom or string to its implementing Adapter module.
  Raises ArgumentError if driver is unsupported.
  """
  @spec for_driver(atom() | String.t()) :: module()
  def for_driver(driver) when is_binary(driver) do
    for_driver(String.to_atom(driver))
  end

  def for_driver(driver) when is_atom(driver) do
    case normalize_driver(driver) do
      :postgres -> Strata.Adapter.Postgres
      :mysql -> Strata.Adapter.MySQL
      :sqlite -> Strata.Adapter.SQLite
      other -> raise ArgumentError, "Unsupported database driver: #{inspect(other)}"
    end
  end

  @doc """
  Normalizes driver string/atom alias to canonical driver atom.
  """
  @spec normalize_driver(atom() | String.t()) :: atom()
  def normalize_driver(driver) when is_atom(driver) do
    driver_str = Atom.to_string(driver) |> String.downcase()

    cond do
      driver_str in ["sqlite", "sqlite3"] -> :sqlite
      driver_str in ["postgres", "postgresql", "postgrex"] -> :postgres
      driver_str in ["mysql", "mariadb", "myxql"] -> :mysql
      true -> driver
    end
  end

  def normalize_driver(driver) when is_binary(driver) do
    normalize_driver(String.to_atom(driver))
  end

  @doc """
  Returns default port for given driver atom or string.
  """
  @spec default_port(atom() | String.t()) :: integer()
  def default_port(driver) do
    try do
      adapter = for_driver(driver)
      adapter.default_port()
    rescue
      _ -> 0
    end
  end
end
