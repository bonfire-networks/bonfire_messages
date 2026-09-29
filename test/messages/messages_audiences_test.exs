defmodule Bonfire.Messages.MessagesAudiencesTest do
  @moduledoc """
  The "Hide notifications and messages from" switches, applied to direct messages: the same audiences and settings as the notifications feed (`Bonfire.Social.Notifications.audiences/0`), for the audiences whose surfaces include messages.
  """
  use Bonfire.Messages.DataCase, async: true
  @moduletag :backend

  alias Bonfire.Messages
  alias Bonfire.Me.Fake
  alias Bonfire.Social.Graph.Follows
  alias Bonfire.Social.Notifications

  setup do
    me = Fake.fake_user!()
    friend = Fake.fake_user!()
    stranger = Fake.fake_user!()

    {:ok, _} = Follows.follow(me, friend)

    {:ok, from_friend} =
      Messages.send(friend, %{to_circles: [me.id], post_content: %{html_body: "from a friend"}})

    {:ok, from_stranger} =
      Messages.send(stranger, %{
        to_circles: [me.id],
        post_content: %{html_body: "from a stranger"}
      })

    {:ok,
     me: me,
     friend: friend,
     stranger: stranger,
     from_friend: from_friend,
     from_stranger: from_stranger}
  end

  defp hiding(user, audience) do
    current_user(
      Bonfire.Common.Settings.put(Notifications.audience_key(audience), :hide, current_user: user)
    )
  end

  # the ids listed, flat and as threads, which are two queries
  defp listed(user, opts \\ []) do
    for shape <- [[], [latest_in_threads: true]] do
      %{edges: edges} = Messages.list(user, nil, shape ++ opts)
      MapSet.new(edges, & &1.id)
    end
  end

  test "hiding nobody lists both", %{
    me: me,
    from_friend: from_friend,
    from_stranger: from_stranger
  } do
    for ids <- listed(me) do
      assert from_friend.id in ids
      assert from_stranger.id in ids
    end
  end

  test "with people you don't follow hidden, a stranger's message is left out and a friend's stays",
       %{me: me, from_friend: from_friend, from_stranger: from_stranger} do
    me = hiding(me, :not_followed)

    for ids <- listed(me) do
      assert from_friend.id in ids
      refute from_stranger.id in ids
    end
  end

  test "the hidden list has what the switches leave out, and nothing else",
       %{me: me, from_friend: from_friend, from_stranger: from_stranger} do
    me = hiding(me, :not_followed)

    for ids <- listed(me, hidden: true) do
      assert from_stranger.id in ids
      refute from_friend.id in ids
    end
  end

  test "hiding nobody leaves the hidden list empty", %{me: me} do
    for ids <- listed(me, hidden: true), do: assert(MapSet.size(ids) == 0)
  end

  test "someone who follows nobody and hides people they don't follow still sees what they sent" do
    loner = Fake.fake_user!()
    other = Fake.fake_user!()

    {:ok, sent} =
      Messages.send(loner, %{to_circles: [other.id], post_content: %{html_body: "from me"}})

    loner = hiding(loner, :not_followed)

    for ids <- listed(loner), do: assert(sent.id in ids)
  end

  # a message tags everyone it's addressed to, so it is a mention: this row hides a stranger's messages as well as their mentions
  test "hiding mentions from people you don't follow leaves out a stranger's message, and a friend's stays",
       %{me: me, from_friend: from_friend, from_stranger: from_stranger} do
    me = hiding(me, :not_followed_making_contact)

    for ids <- listed(me) do
      assert from_friend.id in ids
      refute from_stranger.id in ids
    end
  end

  # some clients (the encrypted ones) put a message in a conversation by its thread alone, with no reply link: it still answers whoever started the conversation
  test "hiding strangers making contact keeps a stranger's message in a conversation you started, even with no reply link",
       %{me: me, stranger: stranger, from_stranger: from_stranger} do
    {:ok, mine} =
      Messages.send(me, %{to_circles: [stranger.id], post_content: %{html_body: "I wrote first"}})

    {:ok, theirs} =
      Messages.send(stranger, %{
        to_circles: [me.id],
        post_content: %{html_body: "their answer, threaded but not a reply"},
        thread_id: mine.id
      })

    # the premise: in my conversation, with no reply link
    theirs = Bonfire.Common.Repo.preload(theirs, :replied, force: true)
    assert theirs.replied.thread_id == mine.id
    assert is_nil(theirs.replied.reply_to_id)

    me = hiding(me, :not_followed_making_contact)

    %{edges: edges} = Messages.list(me)
    ids = MapSet.new(edges, & &1.id)

    assert theirs.id in ids
    refute from_stranger.id in ids
  end

  test "hiding strangers making contact keeps a stranger's reply in a conversation you started",
       %{me: me, stranger: stranger, from_stranger: from_stranger} do
    {:ok, mine} =
      Messages.send(me, %{to_circles: [stranger.id], post_content: %{html_body: "I wrote first"}})

    {:ok, their_reply} =
      Messages.send(stranger, %{
        to_circles: [me.id],
        post_content: %{html_body: "their answer"},
        reply_to_id: mine.id
      })

    me = hiding(me, :not_followed_making_contact)

    # flat only: as threads, each conversation is listed by its latest message
    %{edges: edges} = Messages.list(me)
    ids = MapSet.new(edges, & &1.id)

    assert their_reply.id in ids
    assert mine.id in ids
    refute from_stranger.id in ids
  end
end
