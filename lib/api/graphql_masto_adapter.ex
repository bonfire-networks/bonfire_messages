if Application.compile_env(:bonfire_api_graphql, :modularity) != :disabled do
  defmodule Bonfire.Messages.API.GraphQLMasto.Adapter do
    @moduledoc "Conversations/DM API endpoints for Mastodon-compatible client apps"

    use Bonfire.Common.Utils
    use Arrows
    import Untangle

    alias Bonfire.API.GraphQL.RestAdapter
    alias Bonfire.API.MastoCompat.Mappers
    alias Bonfire.API.MastoCompat.PaginationHelpers
    alias Bonfire.API.MastoCompat.{Fragments, Helpers}

    @conversations_query """
    query ($first: Int, $after: String, $before: String) {
      my_conversations: myConversations(first: $first, after: $after, before: $before) {
        edges { node { #{Fragments.conversation_fields()} } }
        page_info: pageInfo { start_cursor: startCursor end_cursor: endCursor }
      }
    }
    """

    @conversation_query """
    query ($id: ID!) { conversation(id: $id) { #{Fragments.conversation_fields()} } }
    """

    @doc "List conversations (DM threads) for the current user."
    def conversations(params, conn) do
      current_user = conn.assigns[:current_user]

      if is_nil(current_user) do
        RestAdapter.error_fn({:error, :unauthorized}, conn)
      else
        pagination_opts = build_conversation_pagination_opts(params)

        # Mastodon's cursors are message ids: `max_id` is `after`, `min_id` and `since_id` are `before`, as `Messages.list/3` has always taken them
        variables =
          %{
            "first" => pagination_opts[:limit],
            "after" => pagination_opts[:after],
            "before" => pagination_opts[:before]
          }
          |> Map.reject(fn {_, v} -> is_nil(v) end)

        case Helpers.run_query(@conversations_query, current_user, variables) do
          # any error, even beside partial data: a field that failed would otherwise leave a conversation silently empty
          {:ok, %{errors: [_ | _] = errors}} ->
            RestAdapter.error_fn({:error, errors}, conn)

          {:ok, %{data: %{my_conversations: %{edges: edges, page_info: page_info}}}} ->
            conversations =
              edges
              |> Enum.map(&Mappers.Conversation.from_graphql(&1, current_user: current_user))
              |> Enum.reject(&is_nil/1)

            # only the cursors: Relay's `has_next_page` is false on the last page, where the Link headers have always offered a next one
            conn
            |> PaginationHelpers.add_simple_link_headers(
              params,
              Map.take(page_info, [:start_cursor, :end_cursor]),
              conversations
            )
            |> RestAdapter.json(conversations)

          other ->
            error(other, "Unexpected result from my_conversations")
            RestAdapter.json(conn, [])
        end
      end
    end

    @doc "Mark a conversation as read and return updated conversation."
    def mark_conversation_read(%{"id" => thread_id}, conn) do
      current_user = conn.assigns[:current_user]

      if is_nil(current_user) do
        RestAdapter.error_fn({:error, :unauthorized}, conn)
      else
        case Bonfire.Social.Seen.mark_seen(conn.assigns, thread_id) do
          {:ok, _} ->
            get_single_conversation(thread_id, current_user, conn)

          {:error, reason} ->
            RestAdapter.error_fn({:error, reason}, conn)

          _ ->
            # mark_seen may return different formats, try to get conversation anyway
            get_single_conversation(thread_id, current_user, conn)
        end
      end
    end

    @doc "Hide a conversation from the user's list (removes from inbox, not actual messages)."
    def delete_conversation(%{"id" => thread_id}, conn) do
      current_user = conn.assigns[:current_user]

      if is_nil(current_user) do
        RestAdapter.error_fn({:error, :unauthorized}, conn)
      else
        inbox_feed_id = Bonfire.Social.Feeds.feed_id(:inbox, current_user)

        if inbox_feed_id do
          Bonfire.Social.FeedActivities.delete(
            feed_id: inbox_feed_id,
            object_id: thread_id
          )
        end

        RestAdapter.json(conn, %{})
      end
    end

    defp get_single_conversation(thread_id, current_user, conn) do
      case Helpers.run_query(@conversation_query, current_user, %{"id" => thread_id}) do
        {:ok, %{errors: [_ | _] = errors}} ->
          RestAdapter.error_fn({:error, errors}, conn)

        {:ok, %{data: %{conversation: node}}} when is_map(node) ->
          case Mappers.Conversation.from_graphql(node, current_user: current_user) do
            nil -> RestAdapter.error_fn({:error, :not_found}, conn)
            conversation -> RestAdapter.json(conn, conversation)
          end

        _ ->
          RestAdapter.error_fn({:error, :not_found}, conn)
      end
    end

    defp build_conversation_pagination_opts(params) do
      # Mastodon conversations cap at 40
      limit = PaginationHelpers.validate_limit(params["limit"] || params[:limit], max: 40)
      PaginationHelpers.build_pagination_opts(params, limit)
    end
  end
end
