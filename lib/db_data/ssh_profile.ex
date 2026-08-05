defmodule DBData.SSHProfile do
  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          host: String.t(),
          port: integer(),
          username: String.t() | nil,
          password: String.t() | nil,
          identity_file: String.t() | nil,
          passphrase: String.t() | nil
        }

  defstruct [
    :id,
    :name,
    :host,
    port: 22,
    username: nil,
    password: nil,
    identity_file: nil,
    passphrase: nil
  ]
end
