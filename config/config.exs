import Config

config :db_data, DBData.Web.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  url: [host: "localhost"],
  secret_key_base: "SuperSecretKeyBaseForDBDataTUIWebMode1234567890123456789012345678901234567890",
  pubsub_server: DBData.PubSub,
  render_errors: [html: DBData.Web.ErrorHTML, accepts: ~w(html json)],
  live_view: [signing_salt: "DBDataSigningSalt123"],
  debug_errors: true

config :phoenix, :json_library, Jason

if Mix.env() == :dev do
  config :db_data, DBData.Web.Endpoint,
    code_reloader: true,
    live_reload: [
      patterns: [
        ~r"lib/db_data/.*(ex)$"
      ]
    ]
end
