defmodule DBData.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      DBData.SSHProfileStore,
      DBData.ConfigStore,
      DBData.DataStore,
      DBData.LogStore,
      {DynamicSupervisor, name: DBData.ConnectionSupervisor, strategy: :one_for_one}
    ]

    opts = [strategy: :one_for_one, name: DBData.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
