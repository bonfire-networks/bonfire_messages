defmodule Bonfire.Messages.Fake do
  import Bonfire.Common.Simulation
  # import Bonfire.Me.Fake
  # alias Bonfire.Common.Utils
  alias Bonfire.Posts
  alias Bonfire.Common
  alias Common.Types

  def fake_post!(user, boundary \\ nil, attrs \\ nil, opts \\ []) do
    {:ok, post} =
      Posts.publish(
        [
          current_user: user,
          post_attrs:
            attrs ||
              %{
                post_content: %{
                  name: title(),
                  # summary: summary(),
                  html_body: markdown()
                }
              },
          boundary: boundary || "public",
          debug: true,
          crash: true
        ] ++ List.wrap(opts)
      )

    post
  end

  def fake_comment!(user, reply_to, boundary \\ nil, attrs \\ nil) do
    {:ok, post} =
      Posts.publish(
        current_user: user,
        post_attrs:
          attrs ||
            %{
              reply_to_id: Types.uid(reply_to),
              post_content: %{
                summary: "summary",
                name: "name",
                html_body: "<p>epic html message</p>"
              }
            },
        boundary: boundary || "public",
        debug: true,
        crash: true
      )

    post
  end

  def fake_remote_user!() do
    {:ok, user} = Bonfire.Federate.ActivityPub.Simulate.fake_remote_user()
    user
  end
end
