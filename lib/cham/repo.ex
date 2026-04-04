defmodule Cham.Repo do
  use Ecto.Repo,
    otp_app: :cham,
    adapter: Ecto.Adapters.Postgres
end
