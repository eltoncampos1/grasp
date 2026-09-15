import Config

config :sample_app, SampleAppWeb.Endpoint, secret_key_base: String.duplicate("s", 64)
