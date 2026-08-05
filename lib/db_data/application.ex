defmodule DBData.Application do
  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    args = System.argv()

    web_mode? =
      "web" in args or
        "phx.server" in args or
        System.get_env("WEB") == "true" or
        System.get_env("PORT") != nil or
        Application.get_env(:db_data, DBData.Web.Endpoint)[:server] == true

    if web_mode? do
      port = parse_port()
      endpoint_config = Application.get_env(:db_data, DBData.Web.Endpoint, [])
      http_config = Keyword.get(endpoint_config, :http, []) |> Keyword.put(:port, port)

      endpoint_config =
        endpoint_config
        |> Keyword.put(:server, true)
        |> Keyword.put(:http, http_config)

      Application.put_env(:db_data, DBData.Web.Endpoint, endpoint_config)
      IO.puts("🚀 DBData Web Server starting on http://localhost:#{port}")
    end

    base_children = [
      {Phoenix.PubSub, name: DBData.PubSub},
      DBData.SSHProfileStore,
      DBData.ConfigStore,
      DBData.DataStore,
      {DynamicSupervisor, name: DBData.ConnectionSupervisor, strategy: :one_for_one}
    ]

    children =
      if web_mode? do
        base_children ++ [DBData.Web.Endpoint]
      else
        base_children
      end

    opts = [strategy: :one_for_one, name: DBData.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp parse_port do
    case System.get_env("PORT") do
      nil -> 4000
      val ->
        case Integer.parse(val) do
          {num, ""} -> num
          _ -> 4000
        end
    end
  end
end
