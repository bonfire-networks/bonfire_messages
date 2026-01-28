if Application.compile_env(:bonfire_api_graphql, :modularity) != :disabled do
  defmodule Bonfire.Messages.API.GraphQLMasto.Adapter do
    @moduledoc "Conversations/DM API endpoints for Mastodon-compatible client apps"

    use Bonfire.Common.Utils
    use Arrows
    import Untangle

    alias Bonfire.API.GraphQL.RestAdapter
    alias Bonfire.API.MastoCompat.Mappers
    alias Bonfire.API.MastoCompat.PaginationHelpers

    # ==========================================
    # Conversations API (DM threads)
    # ==========================================

    @doc """
    List conversations (DM threads) for the current user.

    Returns a list of Mastodon-compatible Conversation objects with:
    - id: thread ID
    - accounts: participants
    - unread: whether there are unseen messages
    - last_status: the most recent message
    """
    def conversations(params, conn) do
      current_user = conn.assigns[:current_user]

      if is_nil(current_user) do
        RestAdapter.error_fn({:error, :unauthorized}, conn)
      else
        pagination_opts = build_conversation_pagination_opts(params)

        opts =
          Keyword.merge(pagination_opts,
            current_user: current_user,
            latest_in_threads: true,
            # Preloads needed for Conversation/Status mappers:
            # - :with_object_more loads post_content and replied
            # - :with_subject loads activity.subject (sender) for account
            # - :with_seen for unread tracking
            # - :tags for participants
            preload: [:with_object_more, :with_subject, :with_seen, :tags]
          )

        case Bonfire.Messages.list(current_user, nil, opts) do
          %{edges: edges, page_info: page_info} ->
            conversations =
              edges
              |> Enum.map(&Mappers.Conversation.from_thread(&1, current_user: current_user))
              |> Enum.reject(&is_nil/1)

            conn
            |> PaginationHelpers.add_simple_link_headers(params, page_info, conversations)
            |> RestAdapter.json(conversations)

          {:error, reason} ->
            RestAdapter.error_fn({:error, reason}, conn)

          other ->
            error(other, "Unexpected result from Messages.list")
            RestAdapter.json(conn, [])
        end
      end
    end

    @doc """
    Mark a conversation as read.

    Marks all messages in the thread as seen by the current user.
    Returns the updated conversation object.
    """
    def mark_conversation_read(%{"id" => thread_id}, conn) do
      current_user = conn.assigns[:current_user]

      if is_nil(current_user) do
        RestAdapter.error_fn({:error, :unauthorized}, conn)
      else
        # Mark the thread as seen
        case Bonfire.Social.Seen.mark_seen(current_user, thread_id, current_user: current_user) do
          {:ok, _} ->
            # Return the updated conversation
            get_single_conversation(thread_id, current_user, conn)

          {:error, reason} ->
            RestAdapter.error_fn({:error, reason}, conn)

          _ ->
            # mark_seen may return different formats, try to get conversation anyway
            get_single_conversation(thread_id, current_user, conn)
        end
      end
    end

    # Get a single conversation by thread ID
    defp get_single_conversation(thread_id, current_user, conn) do
      # Try to load the thread's latest message
      opts = [
        current_user: current_user,
        preload: [:with_object_more, :with_subject, :with_seen, :tags]
      ]

      case Bonfire.Messages.read(thread_id, opts) do
        {:ok, message} ->
          conversation =
            Mappers.Conversation.from_thread(message, current_user: current_user)

          if conversation do
            RestAdapter.json(conn, conversation)
          else
            RestAdapter.error_fn({:error, :not_found}, conn)
          end

        {:error, reason} ->
          RestAdapter.error_fn({:error, reason}, conn)

        _ ->
          RestAdapter.error_fn({:error, :not_found}, conn)
      end
    end

    # Build pagination opts for conversations query
    defp build_conversation_pagination_opts(params) do
      limit = PaginationHelpers.validate_limit(params["limit"] || params[:limit])
      PaginationHelpers.build_pagination_opts(params, limit)
    end
  end
end
