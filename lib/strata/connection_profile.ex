defmodule Strata.ConnectionProfile do
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
          ssh: map() | nil,
          auto_connect: boolean(),
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
    :ssh,
    auto_connect: false,
    options: %{}
  ]
end
