defmodule Bonfire.Messages.Integration do
  use Arrows
  use Bonfire.Common.Config
  use Bonfire.Common.Utils
  # alias Bonfire.Data.Social.Follow
  # import Untangle

  declare_extension("Messages",
    icon: "carbon:email",
    emoji: "✉️",
    description: l("Functionality for writing and reading private messages.")
  )

  def repo, do: Config.repo()

  def mailer, do: Config.get!(:mailer_module)
end
