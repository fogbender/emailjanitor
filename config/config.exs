import Config

# Build from the package's pinned PSL snapshot; never fetch mutable data at compile time.
config :domainatrex, fetch_latest: false

# The adapter also removes SDK request lifecycle hooks before dispatch, because
# this pinned SDK can put raw text in exception metadata despite payloads:none.
config :req_llm, telemetry: [payloads: :none], debug: false, load_dotenv: false
config :ex_aws, http_client: ExAws.Request.Req, json_codec: Jason
