defmodule EmailJanitor.Jobs.Migration do
  @moduledoc false
  use Ecto.Migration
  def up, do: Oban.Migration.up(prefix: prefix())
  def down, do: Oban.Migration.down(prefix: prefix())
end
