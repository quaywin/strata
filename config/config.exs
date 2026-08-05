import Config

config :strata, Strata.Web.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  url: [host: "localhost"],
  secret_key_base: "SuperSecretKeyBaseForStrataTUIWebMode1234567890123456789012345678901234567890",
  pubsub_server: Strata.PubSub,
  render_errors: [html: Strata.Web.ErrorHTML, accepts: ~w(html json)],
  live_view: [signing_salt: "StrataSigningSalt123"],
  debug_errors: true

config :phoenix, :json_library, Jason

if Mix.env() == :dev do
  config :strata, Strata.Web.Endpoint,
    code_reloader: true,
    live_reload: [
      patterns: [
        ~r"lib/strata/.*(ex)$"
      ]
    ]
end
