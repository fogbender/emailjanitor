import Config

# Build from the package's pinned PSL snapshot; never fetch mutable data at compile time.
config :domainatrex, fetch_latest: false

# Normal request payload telemetry is disabled. ReqLLM exception metadata may
# still include transient request text: never export/log its raw error event.
config :req_llm, telemetry: [payloads: :none], debug: false, load_dotenv: false
config :ex_aws, http_client: ExAws.Request.Req, json_codec: Jason
