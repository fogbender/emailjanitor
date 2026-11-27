import Config

# Build from the package's pinned PSL snapshot; never fetch mutable data at compile time.
config :domainatrex, fetch_latest: false
