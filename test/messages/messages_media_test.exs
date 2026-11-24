defmodule Bonfire.Messages.MessagesMediaTest do
  @moduledoc """
  A direct message carries the files its sender uploaded in the composer, as a post does: attached, and placed in its text when the text has their URL (see `Bonfire.Files.InlineMedia`).
  """
  use Bonfire.Messages.DataCase, async: false
  use Bonfire.Common.Utils
  import Ecto.Query

  @moduletag :backend

  alias Bonfire.Messages
  alias Bonfire.Me.Fake

  setup do
    sender = Fake.fake_user!()
    receiver = Fake.fake_user!()
    media = Bonfire.Social.Fake.upload_media(:images, sender)

    {:ok, sender: sender, receiver: receiver, media: media}
  end

  defp attached_media_ids(message) do
    from(f in Bonfire.Files, where: f.id == ^id(message), select: f.media_id)
    |> repo().all()
  end

  test "a message sent with uploaded media has it attached, and its recipient may see it", %{
    sender: sender,
    receiver: receiver,
    media: media
  } do
    {:ok, message} =
      Messages.send(sender, %{
        to_circles: [receiver.id],
        post_content: %{html_body: "Intro\n\n![](#{Bonfire.Files.inline_url(media)})\n\nmore"},
        uploaded_media: [media]
      })

    assert attached_media_ids(message) == [id(media)]
    assert Bonfire.Files.Media.visible?(media, current_user: receiver)
    refute Bonfire.Files.Media.visible?(media, current_user: nil)
  end

  test "control: a message sent without media has none attached", %{
    sender: sender,
    receiver: receiver
  } do
    {:ok, message} =
      Messages.send(sender, %{to_circles: [receiver.id], post_content: %{html_body: "no media"}})

    assert attached_media_ids(message) == []
  end
end
