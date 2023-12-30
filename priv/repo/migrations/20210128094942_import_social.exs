defmodule Bonfire.Messages.Repo.Migrations.ImportSocial  do
  @moduledoc false
  use Ecto.Migration

  import Bonfire.Messages.Migrations

  def change, do: migrate_social()
end
