defmodule DBData.ConnectionProfile do
  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          driver: atom(),
          host: String.t() | nil,
          port: integer() | nil,
          database: String.t() | nil,
          username: String.t() | nil,
          password: String.t() | nil,
          ssh_profile_id: String.t() | nil,
          options: map()
        }

  defstruct [
    :id,
    :name,
    :driver,
    :host,
    :port,
    :database,
    :username,
    :password,
    :ssh_profile_id,
    options: %{}
  ]
end
