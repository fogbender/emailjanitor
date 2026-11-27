defmodule EmailJanitor.SelfHost.Repo do
  @moduledoc "Concrete PostgreSQL repository for the opt-in single-user host."
  use Ecto.Repo, otp_app: :email_janitor, adapter: Ecto.Adapters.Postgres
end
