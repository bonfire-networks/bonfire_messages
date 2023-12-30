defmodule Bonfire.Messages.Integration do
  use Arrows
  alias Bonfire.Common.Config
  use Bonfire.Common.Utils
  # alias Bonfire.Data.Social.Follow
  import Untangle

  def repo, do: Config.repo()

  def mailer, do: Config.get!(:mailer_module)
end
