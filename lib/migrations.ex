defmodule Bonfire.Messages.Migrations do
  @moduledoc false
  use Ecto.Migration
  import Needle.Migration

  def ms(:up) do
    quote do
      require Bonfire.Data.Social.Message.Migration

      Bonfire.Data.Social.Message.Migration.migrate_message()
    end
  end

  def ms(:down) do
    quote do
      require Bonfire.Data.Social.Message.Migration

      Bonfire.Data.Social.Message.Migration.migrate_message()
    end
  end

  defmacro migrate_messages() do
    quote do
      if Ecto.Migration.direction() == :up,
        do: unquote(ms(:up)),
        else: unquote(ms(:down))
    end
  end

  defmacro migrate_messages(dir), do: ms(dir)
end
