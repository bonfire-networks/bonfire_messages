if Application.compile_env(:bonfire_api_graphql, :modularity) != :disabled and
     Code.ensure_loaded?(Absinthe.Schema.Notation) do
  defmodule Bonfire.Messages.API.GraphQL do
    @moduledoc "Direct messages and conversations (the reader's DM threads) for GraphQL"

    use Absinthe.Schema.Notation
    use Absinthe.Relay.Schema.Notation, :modern
    use Bonfire.Common.Utils

    alias Bonfire.API.GraphQL
    alias Bonfire.API.GraphQL.Pagination
    alias Bonfire.Common.Types
    alias Bonfire.Social.Threads

    # the preloads the Mastodon conversations list has always read
    @list_preloads [:with_object_more, :with_subject, :with_seen, :tags]

    # for pagination
    connection(node_type: :conversation)

    @desc "A direct message"
    object :message do
      field(:id, :id)

      # what the viewer did to this message (`:object_interactions`)
      import_fields(:object_interactions)

      field :post_content, :post_content do
        resolve(&Bonfire.Social.API.GraphQL.resolve_post_content/3)
      end

      @desc "The activity that sent this message: its sender is the `subject`; its tags give `mentions` and `hashtags`"
      field :activity, :activity do
        resolve(&Bonfire.Social.API.GraphQL.resolve_loaded_activity/3)
      end

      field :creator, :any_character do
        resolve(&Bonfire.Social.API.GraphQL.resolve_creator/3)
      end
    end

    @desc "A DM thread as the reader sees it, represented by its latest message"
    object :conversation do
      @desc "The id the Mastodon conversations API has always given: the thread id when the latest message's `replied` is loaded, else the latest message's own id"
      field :id, :id do
        resolve(fn message, _, _ -> {:ok, thread_id(message)} end)
      end

      @desc "Whether the reader has not seen the latest message"
      field :unread, :boolean do
        resolve(fn message, _, _ -> {:ok, unread?(message)} end)
      end

      @desc "The thread's participants the reader may see, in `Threads.list_participants/3` order (the latest message's sender first)"
      field :participants, list_of(:any_character) do
        resolve(&resolve_participants/3)
      end

      @desc "Who sent the latest message, as the reader may see them (null when they may not)"
      field :sender, :any_character do
        resolve(&resolve_sender/3)
      end

      field :last_message, :message do
        resolve(fn message, _, _ -> {:ok, message} end)
      end
    end

    object :messages_queries do
      @desc "The reader's DM threads, newest first, each represented by its latest message"
      connection field :my_conversations, node_type: :conversation do
        complexity(&Bonfire.Social.API.GraphQL.page_complexity/2)
        resolve(&list_my_conversations/2)
      end

      @desc "One of the reader's DM threads, by the id of the message that represents it (what the Mastodon conversations API reads back after marking it read)"
      field :conversation, :conversation do
        arg(:id, non_null(:id))
        resolve(&get_conversation/3)
      end
    end

    defp get_conversation(_parent, %{id: id}, info) do
      with {:ok, user} <- GraphQL.current_user_or_not_logged_in(info) do
        # the list's preloads but `:with_subject`: `Messages.read/2` then requires the subject to be the reader (`Activities.ensure_user_loaded!/3`), and the conversation reads its sender's id, not the subject
        Bonfire.Messages.read(id, current_user: user, preload: @list_preloads -- [:with_subject])
      end
    end

    defp list_my_conversations(args, info) do
      with {:ok, user} <- GraphQL.current_user_or_not_logged_in(info) do
        {pagination_args, _} = Pagination.pagination_args_filter(args)

        # Mastodon cursors are message ids, passed through as `after`/`before`, as the conversations API always did
        opts =
          [
            limit: pagination_args[:first],
            after: pagination_args[:after],
            before: pagination_args[:before]
          ]
          |> Enum.reject(fn {_, v} -> is_nil(v) end)
          |> Keyword.merge(current_user: user, latest_in_threads: true, preload: @list_preloads)

        Bonfire.Messages.list(user, nil, opts)
        |> Pagination.connection_paginate(pagination_args)
      end
    end

    defp resolve_participants(message, _args, %{context: %{loader: loader}} = info) do
      current_user = GraphQL.current_user(info)

      keys =
        message
        |> Threads.list_participants(thread_id(message), current_user: current_user)
        |> Enum.map(&Types.uid/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()
        # read with the reader's boundaries, as `characters(ids:)` does, batched across the page: one they may not see is left out
        |> Enum.map(&{&1, current_user})

      loader
      |> Dataloader.load_many(:characters, :character, keys)
      |> Absinthe.Resolution.Helpers.on_load(fn loader ->
        {:ok,
         loader |> Dataloader.get_many(:characters, :character, keys) |> Enum.reject(&is_nil/1)}
      end)
    end

    # the sender read on its own, as the conversations API always did (not only when listed among the participants)
    defp resolve_sender(message, _args, %{context: %{loader: loader}} = info) do
      case e(message, :activity, :subject_id, nil) do
        nil ->
          {:ok, nil}

        sender_id ->
          key = {sender_id, GraphQL.current_user(info)}

          loader
          |> Dataloader.load(:characters, :character, key)
          |> Absinthe.Resolution.Helpers.on_load(fn loader ->
            {:ok, Dataloader.get(loader, :characters, :character, key)}
          end)
      end
    end

    # moved from `Mappers.Conversation.get_thread_id/1`, unchanged
    defp thread_id(message) do
      e(message, :replied, :thread_id, nil) || e(message, :id, nil)
    end

    # moved from `Mappers.Conversation.check_unread/2`, unchanged: the `:with_seen` preload puts the seen edge on the activity
    defp unread?(message) do
      case e(message, :activity, :seen, nil) do
        nil -> true
        false -> true
        seen when is_map(seen) and map_size(seen) == 0 -> true
        [] -> true
        _ -> false
      end
    end
  end
end
