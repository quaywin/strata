defmodule DBData.Application do
  use Application

  @impl true
  def start(_type, _args) do
    base_children = [
      DBData.SSHProfileStore,
      DBData.ConfigStore,
      DBData.DataStore,
      DBData.LogStore,
      {DynamicSupervisor, name: DBData.ConnectionSupervisor, strategy: :one_for_one}
    ]

    children =
      if Mix.env() != :test do
        base_children ++ [{DBData.UI.App, [terminal: true, mouse_capture: true]}]
      else
        base_children
      end

    opts = [strategy: :one_for_one, name: DBData.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
