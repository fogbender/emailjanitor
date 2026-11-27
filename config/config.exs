import Config

# Build from the package's pinned PSL snapshot; never fetch mutable data at compile time.
config :domainatrex, fetch_latest: false

# Email content must never be emitted as request/response telemetry payloads.
config :req_llm, telemetry: [payloads: :none]
