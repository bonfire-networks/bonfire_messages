defmodule Bonfire.Messages.MessagesSeenTest do
  @moduledoc """
  Verifies the seen/unseen behaviour that drives the unread-dot in the
  message threads list. Spike for the bug where the dot only disappears
  after a full page refresh.

  Specifically asserts that:

    * a freshly received message lists with `activity.seen == nil`
    * `Bonfire.Social.Seen.mark_seen/2` on the message flips the
      preloaded `seen` to a populated edge on the next list call
    * `Bonfire.Social.Threads.mark_all_seen/2` (the call we want to wire
      to thread-modal-open) achieves the same outcome end-to-end —
      despite the user_id vs account_id asymmetry between
      `Threads.unseen_query` (joins by user_id) and `Seen.mark_seen`
      (writes by account_id via `normalize_subject`)
  """

  use Bonfire.Messages.DataCase, async: true

  alias Bonfire.Messages
  alias Bonfire.Social.Seen
  alias Bonfire.Social.Threads
  alias Bonfire.Me.Fake

  @html_body "<p>hey there, unread message</p>"

  defp send_message_to(receiver) do
    sender = Fake.fake_user!()

    attrs = %{
      to_circles: [receiver.id],
      post_content: %{html_body: @html_body}
    }

    {:ok, message} = Messages.send(sender, attrs)
    {sender, message}
  end

  defp received_activity(receiver) do
    %{edges: [edge | _]} = Messages.list(receiver)
    edge.activity
  end

  defp thread_id(activity) do
    e(activity, :replied, :thread_id, nil) || id(e(activity, :object, nil))
  end

  describe "seen state in the message threads list" do
    test "a newly received message lists with activity.seen == nil" do
      receiver = Fake.fake_user!()
      {_sender, _message} = send_message_to(receiver)

      activity = received_activity(receiver)

      refute activity.seen,
             "expected the receiver's listed activity to have seen=nil before any mark_seen call, got: #{inspect(activity.seen)}"
    end

    test "Seen.mark_seen on the message makes the next list show seen as a populated edge" do
      receiver = Fake.fake_user!()
      {_sender, message} = send_message_to(receiver)

      assert {:ok, _seen_edge} = Seen.mark_seen(receiver, message)

      activity = received_activity(receiver)

      assert activity.seen,
             "expected activity.seen to be a populated edge after Seen.mark_seen, got nil"
    end

    # The next two tests document a latent bug in `Threads.mark_all_seen`:
    # `Threads.query` excludes the thread root via `where replied.id != thread_id`,
    # so it never marks the root message of a fresh DM thread. We don't use
    # `Threads.mark_all_seen` for the messages flow (we call `Seen.mark_seen`
    # directly), so these tests are here as `@tag :todo` regression markers —
    # they will turn green once the upstream `Threads.query` is fixed.
    @tag :todo
    test "Threads.mark_all_seen flips the preloaded seen on the next list" do
      receiver = Fake.fake_user!()
      {_sender, _message} = send_message_to(receiver)

      activity_before = received_activity(receiver)
      refute activity_before.seen
      tid = thread_id(activity_before)

      assert is_binary(tid),
             "expected to derive a thread_id from the listed activity, got: #{inspect(tid)}"

      Threads.mark_all_seen([thread_id: tid], current_user: receiver)

      activity_after = received_activity(receiver)

      assert activity_after.seen,
             "expected activity.seen to be a populated edge after Threads.mark_all_seen, got nil"
    end

    @tag :todo
    test "Seen.seen?/2 reports true after Threads.mark_all_seen (sanity check at the edge level)" do
      receiver = Fake.fake_user!()
      {_sender, message} = send_message_to(receiver)

      refute Seen.seen?(receiver, message)

      activity = received_activity(receiver)
      tid = thread_id(activity)

      Threads.mark_all_seen([thread_id: tid], current_user: receiver)

      assert Seen.seen?(receiver, message),
             "expected Seen.seen?/2 to return true after Threads.mark_all_seen — if false, the seen edge wasn't persisted (Threads.query excludes the thread root via `where replied.id != thread_id`)"
    end

    test "Seen.mark_seen accepts a binary thread_id and flips seen on next list (call site we will use)" do
      receiver = Fake.fake_user!()
      {_sender, _message} = send_message_to(receiver)

      activity_before = received_activity(receiver)
      refute activity_before.seen
      tid = thread_id(activity_before)

      assert is_binary(tid)
      assert {:ok, _seen_edge} = Seen.mark_seen(receiver, tid)

      activity_after = received_activity(receiver)

      assert activity_after.seen,
             "expected activity.seen to be a populated edge after Seen.mark_seen with a binary id — this is the primitive the modal-open handler will call"
    end

    test "for a multi-message thread, marking the THREAD ROOT does NOT clear seen on the latest activity (regression: pass activity_id, not thread_id)" do
      # Reproduces the bug the user reported: dot reappears after navigating
      # away and back. `query_preload_seen` joins on
      # `activity.id == seen_edge.object_id`. Once a thread has replies, the
      # listed activity is the LATEST message — its id is not the thread_id
      # (= first message's id). Marking the thread root leaves the latest
      # activity's seen edge missing, so the dot is shown again on reload.
      receiver = Fake.fake_user!()
      {sender, first_message} = send_message_to(receiver)

      # second message in same thread, in the opposite direction
      {:ok, _reply} =
        Messages.send(sender, %{
          to_circles: [receiver.id],
          post_content: %{html_body: "<p>follow-up</p>"},
          reply_to_id: first_message.id
        })

      latest_activity = received_activity(receiver)
      refute latest_activity.seen
      thread_root_id = thread_id(latest_activity)
      latest_activity_id = latest_activity.id

      refute thread_root_id == latest_activity_id,
             "test premise broken: thread_id should differ from the latest activity id once a thread has replies"

      # Marking the thread root: does NOT update the latest activity
      Seen.mark_seen(receiver, thread_root_id)

      refute received_activity(receiver).seen,
             "marking the thread root via Seen.mark_seen should leave the latest activity's seen as nil — confirms why we must pass activity_id"

      # Marking the latest activity id: DOES update it
      assert {:ok, _} = Seen.mark_seen(receiver, latest_activity_id)

      assert received_activity(receiver).seen,
             "marking the latest activity id should populate seen on the next list"
    end
  end
end
