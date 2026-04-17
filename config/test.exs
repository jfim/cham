import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :cham, Cham.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "cham_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :cham, ChamWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "vEs521oGIFtiwG9U8dLp5w0++Ip7mkQ3bj0PUV47Dxdqqe7381kaGTMUiBuFZ7z6",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

config :cham, Oban,
  repo: Cham.Repo,
  queues: [general: 5, network: 3, gpu: 1, subscriptions: 2],
  testing: :manual

config :cham, :start_tracker, false
config :cham, :start_orchestrator, false
config :cham, :skip_migrations, true
