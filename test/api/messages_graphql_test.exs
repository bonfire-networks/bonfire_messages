# SPDX-License-Identifier: AGPL-3.0-only
if Application.compile_env(:bonfire_api_graphql, :modularity) != :disabled do
  defmodule Bonfire.Messages.API.GraphQLTest do
    @moduledoc """
    `my_conversations`, the reader's DM threads in GraphQL (team-docs/plans/masto-pure-mappers.md,
    "Conversation mapper", unit 1). The Mastodon conversations API reads it from unit 2.

    Run with: just test extensions/bonfire_messages/test/api/messages_graphql_test.exs
    """

    use Bonfire.Messages.DataCase, async: false

    alias Bonfire.API.GraphQL.Schema
    alias Bonfire.Me.Fake
    alias Bonfire.Messages

    @moduletag :graphql

    @query """
    query ($first: Int, $after: String) {
      my_conversations(first: $first, after: $after) {
        edges {
          node {
            id
            unread
            participants { ... on User { id } }
            sender { ... on User { id } }
            last_message {
              id
              liked_by_me
              post_content { html_body }
              activity { subject { ... on User { id } } }
            }
          }
        }
        page_info { start_cursor end_cursor }
      }
    }
    """

    setup do
      viewer = Fake.fake_user!(Fake.fake_account!())
      {:ok, viewer: viewer, other: Fake.fake_user!()}
    end

    test "a conversation: id, unread, participants and the latest message", %{
      viewer: viewer,
      other: other
    } do
      third = Fake.fake_user!()
      first = send_dm(other, [viewer, third], "<p>one</p>")
      _ = send_dm(third, [viewer, other], "<p>two</p>", %{reply_to_id: first.id})
      last = send_dm(other, [viewer, third], "<p>three</p>", %{reply_to_id: first.id})
      {:ok, _} = Bonfire.Social.Likes.like(viewer, last.id)

      assert [conversation] = nodes(run(viewer, %{}))

      # the latest message's id, as the Mastodon API has always answered
      assert conversation["id"] == last.id
      assert conversation["unread"] == true
      # `Threads.list_participants/3` order: the latest sender, the replied-to author, the recipients
      assert node_ids(conversation["participants"]) == [other.id, viewer.id, third.id]
      # read on its own, not taken from the participants
      assert conversation["sender"] == %{"id" => other.id}

      assert conversation["last_message"] == %{
               "id" => last.id,
               "liked_by_me" => true,
               "post_content" => %{"html_body" => "<p>three</p>"},
               "activity" => %{"subject" => %{"id" => other.id}}
             }
    end

    test "a participant who ghosted the reader is left out", %{viewer: viewer, other: other} do
      third = Fake.fake_user!()
      _ = send_dm(other, [viewer, third], "<p>with a ghost</p>")
      {:ok, _} = Bonfire.Boundaries.Blocks.block(viewer, :ghost, current_user: third)

      assert [conversation] = nodes(run(viewer, %{}))
      assert node_ids(conversation["participants"]) == [other.id, viewer.id]
    end

    test "pages by message id, with the raw cursors the list gives", %{viewer: viewer} do
      [oldest, middle, newest] =
        for i <- 1..3, do: send_dm(Fake.fake_user!(), viewer, "<p>thread #{i}</p>")

      page = run(viewer, %{"first" => 2})
      assert node_ids(nodes(page)) == [newest.id, middle.id]
      assert page_info(page) == %{"start_cursor" => nil, "end_cursor" => middle.id}

      page = run(viewer, %{"first" => 2, "after" => middle.id})
      assert node_ids(nodes(page)) == [oldest.id]
      assert page_info(page) == %{"start_cursor" => oldest.id, "end_cursor" => nil}
    end

    @conversation_query """
    query ($id: ID!) {
      conversation(id: $id) {
        id
        unread
        participants { ... on User { id } }
        last_message { id post_content { html_body } }
      }
    }
    """

    test "conversation(id:) reads one of the reader's threads, and nobody else's", %{
      viewer: viewer,
      other: other
    } do
      message = send_dm(other, viewer, "<p>just us</p>")

      assert {:ok, %{data: %{"conversation" => conversation}}} =
               Absinthe.run(@conversation_query, Schema,
                 variables: %{"id" => message.id},
                 context: Schema.context(%{current_user: viewer})
               )

      assert conversation == %{
               "id" => message.id,
               "unread" => true,
               "participants" => [%{"id" => other.id}, %{"id" => viewer.id}],
               "last_message" => %{
                 "id" => message.id,
                 "post_content" => %{"html_body" => "<p>just us</p>"}
               }
             }

      outsider = Fake.fake_user!(Fake.fake_account!())

      assert {:ok, result} =
               Absinthe.run(@conversation_query, Schema,
                 variables: %{"id" => message.id},
                 context: Schema.context(%{current_user: outsider})
               )

      assert get_in(result, [:data, "conversation"]) == nil
      assert [_ | _] = result[:errors]
    end

    test "needs a signed-in reader" do
      assert {:ok, %{errors: [_ | _]}} =
               Absinthe.run(@query, Schema, variables: %{}, context: Schema.context(%{}))
    end

    defp run(user, variables) do
      assert {:ok, %{data: %{"my_conversations" => page}} = result} =
               Absinthe.run(@query, Schema,
                 variables: variables,
                 context: Schema.context(%{current_user: user})
               )

      refute result[:errors]
      page
    end

    defp nodes(page), do: Enum.map(page["edges"], & &1["node"])
    defp page_info(page), do: page["page_info"]
    defp node_ids(list), do: Enum.map(list, & &1["id"])

    defp send_dm(from, to, html, extra \\ %{}) do
      {:ok, message} =
        Messages.send(
          from,
          Map.merge(
            %{
              to_circles: to |> List.wrap() |> Enum.map(& &1.id),
              post_content: %{html_body: html}
            },
            extra
          )
        )

      message
    end
  end
end
