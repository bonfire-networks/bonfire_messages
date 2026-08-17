defmodule Bonfire.Messages.MessagesTest do
  use Bonfire.Messages.DataCase, async: true

  alias Bonfire.Messages
  alias Bonfire.Social.Objects
  alias Bonfire.Social.Feeds
  alias Bonfire.Social.FeedActivities

  alias Bonfire.Me.Fake
  import Untangle

  @plain_body "hey receiver, you have an epic text message"
  @html_body "<p>hey receiver, you have an epic html message</p>"
  @link_url "https://example.com/some-page"
  @body_with_link "check out #{@link_url} please"

  test "can message a user" do
    sender = Fake.fake_user!()
    receiver = Fake.fake_user!()

    attrs = %{
      to_circles: [receiver.id],
      post_content: %{html_body: @plain_body}
    }

    assert {:ok, message} = Messages.send(sender, attrs)
    assert message.post_content.html_body =~ @plain_body
  end

  test "can list messages I sent" do
    sender = Fake.fake_user!()
    receiver = Fake.fake_user!()
    attrs = %{to_circles: [receiver.id], post_content: %{html_body: @html_body}}
    assert {:ok, message} = Messages.send(sender, attrs)
    assert %{edges: [fp]} = Messages.list(sender)
    assert fp.id == message.id
    # also via thread view (latest_in_threads path)
    assert %{edges: [fp2]} = Messages.list(sender, nil, latest_in_threads: true)
    assert fp2.id == message.id
  end

  test "can list messages I sent to a specific person" do
    sender = Fake.fake_user!()
    receiver = Fake.fake_user!()
    attrs = %{to_circles: [receiver.id], post_content: %{html_body: @html_body}}
    assert {:ok, message} = Messages.send(sender, attrs)
    assert %{edges: feed} = Messages.list(sender, receiver)
    assert m = List.first(feed)
    assert m.id == message.id
  end

  test "can list messages sent to me" do
    sender = Fake.fake_user!()
    receiver = Fake.fake_user!()
    attrs = %{to_circles: [receiver.id], post_content: %{html_body: @html_body}}
    assert {:ok, message} = Messages.send(sender, attrs)
    assert %{edges: feed} = Messages.list(receiver)
    assert m = List.first(feed)
    assert m.id == message.id
    # also via thread view (latest_in_threads path)
    assert %{edges: feed2} = Messages.list(receiver, nil, latest_in_threads: true)
    assert List.first(feed2).id == message.id
  end

  test "can list messages sent to me by a specific person" do
    sender = Fake.fake_user!()
    receiver = Fake.fake_user!()

    attrs = %{to_circles: [receiver.id], post_content: %{html_body: @html_body}}

    assert {:ok, message} = Messages.send(sender, attrs)

    assert %{edges: feed} = Messages.list(receiver, sender)
    assert m = List.first(feed)
    assert m.id == message.id
    # also via thread view (latest_in_threads path)
    assert %{edges: feed2} = Messages.list(receiver, sender, latest_in_threads: true)
    assert List.first(feed2).id == message.id
  end

  test "can read a message I send, or sent to me" do
    sender = Fake.fake_user!()
    receiver = Fake.fake_user!()

    attrs = %{to_circles: [receiver.id], post_content: %{html_body: @html_body}}

    assert {:ok, message} = Messages.send(sender, attrs)

    assert {:ok, _} = Messages.read(message.id, current_user: sender)
    assert {:ok, _} = Messages.read(message.id, current_user: receiver)
    assert {:ok, _} = Objects.read(message.id, current_user: sender)
    assert {:ok, _} = Objects.read(message.id, current_user: receiver)
  end

  test "random person CANNOT list messages I sent to another person" do
    sender = Fake.fake_user!()
    receiver = Fake.fake_user!()
    other = Fake.fake_user!()

    attrs = %{to_circles: [receiver.id], post_content: %{html_body: @html_body}}

    assert {:ok, message} = Messages.send(sender, attrs)

    refute match?(%{edges: [_]}, Messages.list(other))
    refute match?(%{edges: [_]}, Messages.list(sender, other))
    refute match?(%{edges: [_]}, Messages.list(other, sender))
    # also via thread view (latest_in_threads path)
    refute match?(%{edges: [_]}, Messages.list(other, nil, latest_in_threads: true))
  end

  test "random person CANNOT read a message I sent to another person" do
    sender = Fake.fake_user!()
    receiver = Fake.fake_user!()
    other = Fake.fake_user!()

    attrs = %{to_circles: [receiver.id], post_content: %{html_body: @html_body}}

    assert {:ok, message} = Messages.send(sender, attrs)

    assert {:error, _} = Messages.read(message.id, current_user: other)
    assert {:error, _} = Objects.read(message.id, current_user: other)
  end

  # we don't show messages in notifications?
  @tag :todo
  test "messaging someone appears in their notifications but does NOT appear in my own notifications" do
    sender = Fake.fake_user!()
    receiver = Fake.fake_user!()
    attrs = %{to_circles: [receiver.id], post_content: %{html_body: @html_body}}

    assert {:ok, message} = Messages.send(sender, attrs)

    assert Bonfire.Social.FeedLoader.feed_contains?(:notifications, message,
             current_user: receiver
           )

    refute Bonfire.Social.FeedLoader.feed_contains?(:notifications, message, current_user: sender)
  end

  # we don't show messages in notifications?
  @tag :todo
  test "messaging someone else does NOT appear in a 3rd party's notifications" do
    sender = Fake.fake_user!()
    receiver = Fake.fake_user!()
    attrs = %{to_circles: [receiver.id], post_content: %{html_body: @html_body}}
    assert {:ok, message} = Messages.send(sender, attrs)
    third = Fake.fake_user!()

    refute Bonfire.Social.FeedLoader.feed_contains?(:notifications, message, current_user: third)
  end

  test "messaging someone does NOT appear in their home feed" do
    sender = Fake.fake_user!()
    receiver = Fake.fake_user!()
    attrs = %{to_circles: [receiver.id], post_content: %{html_body: @html_body}}
    assert {:ok, message} = Messages.send(sender, attrs)
    refute Bonfire.Social.FeedLoader.feed_contains?(:my, message, current_user: receiver)
  end

  test "messaging someone does NOT appear in their instance feed" do
    sender = Fake.fake_user!()
    receiver = Fake.fake_user!()
    attrs = %{to_circles: [receiver.id], post_content: %{html_body: @html_body}}
    assert {:ok, message} = Messages.send(sender, attrs)

    refute Bonfire.Social.FeedLoader.feed_contains?(:local, message, current_user: receiver)
  end

  test "messaging someone does NOT appear in my instance feed" do
    sender = Fake.fake_user!()
    receiver = Fake.fake_user!()
    attrs = %{to_circles: [receiver.id], post_content: %{html_body: @html_body}}
    assert {:ok, message} = Messages.send(sender, attrs)

    refute Bonfire.Social.FeedLoader.feed_contains?(:local, message, current_user: sender)
  end

  test "messaging someone does NOT appear in a 3rd party's instance feed" do
    sender = Fake.fake_user!()
    receiver = Fake.fake_user!()
    attrs = %{to_circles: [receiver.id], post_content: %{html_body: @html_body}}
    assert {:ok, message} = Messages.send(sender, attrs)
    third = Fake.fake_user!()

    refute Bonfire.Social.FeedLoader.feed_contains?(:local, message, current_user: third)
  end

  test "messaging someone does NOT appear in the public instance feed" do
    sender = Fake.fake_user!()
    receiver = Fake.fake_user!()
    attrs = %{to_circles: [receiver.id], post_content: %{html_body: @html_body}}
    assert {:ok, message} = Messages.send(sender, attrs)
    refute Bonfire.Social.FeedLoader.feed_contains?(:local, message)
  end

  describe "links in messages" do
    # renders stored content the same way `Bonfire.UI.Social.Activity.HtmlBodyLive` does
    defp as_rendered(html_body) do
      Bonfire.UI.Common.rich(html_body, sanitize: true)
      |> Phoenix.HTML.safe_to_string()
    end

    test "a URL in a sent message is linkified and recorded" do
      sender = Fake.fake_user!()
      receiver = Fake.fake_user!()

      attrs = %{
        to_circles: [receiver.id],
        post_content: %{html_body: @body_with_link}
      }

      assert {:ok, message} = Messages.send(sender, attrs)

      assert @link_url in (message.post_content.urls || [])
      assert as_rendered(message.post_content.html_body) =~ "href=\"#{@link_url}\""
    end
  end

  describe "mentions & hashtags in messages (must stay excluded)" do
    defp tag_ids(message), do: repo().maybe_preload(message, :tags) |> e(:tags, []) |> Enums.ids()

    test "@mentioning a third party in a message does not tag, notify, or expose it to them" do
      sender = Fake.fake_user!()
      receiver = Fake.fake_user!()
      bystander = Fake.fake_user!()

      attrs = %{
        to_circles: [receiver.id],
        post_content: %{
          html_body: "hey @#{bystander.character.username} #{@body_with_link}"
        }
      }

      assert {:ok, message} = Messages.send(sender, attrs)

      tag_ids = tag_ids(message)
      assert receiver.id in tag_ids, "the recipient should be tagged"
      refute bystander.id in tag_ids, "a mentioned bystander should NOT be tagged"

      assert (message.post_content.mentions || []) == []

      refute Bonfire.Social.FeedLoader.feed_contains?(:notifications, message,
               current_user: bystander
             )

      assert {:error, _} = Messages.read(message.id, current_user: bystander)
    end

    test "a #hashtag in a message is not tagged" do
      sender = Fake.fake_user!()
      receiver = Fake.fake_user!()
      hashtag = "notatag#{System.unique_integer([:positive])}"

      attrs = %{
        to_circles: [receiver.id],
        post_content: %{html_body: "psst #{@body_with_link} ##{hashtag}"}
      }

      assert {:ok, message} = Messages.send(sender, attrs)

      assert [receiver.id] == tag_ids(message)

      assert (message.post_content.hashtags || []) == []
      assert {:error, _} = Bonfire.Tag.get_hashtag(hashtag)
    end
  end
end
