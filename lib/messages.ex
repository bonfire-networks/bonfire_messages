defmodule Bonfire.Messages do
  @moduledoc "./README.md" |> File.stream!() |> Enum.drop(1) |> Enum.join()

  use Arrows
  use Bonfire.Common.Repo
  use Bonfire.Common.Utils
  import Untangle
  alias Bonfire.Social
  # alias Ecto.Changeset

  alias Bonfire.Data.Social.Message
  # alias Bonfire.Data.Social.PostContent
  # alias Bonfire.Data.Social.Replied

  # alias Bonfire.Me.Characters

  alias Bonfire.Social.Activities
  alias Bonfire.Social.FeedActivities
  alias Bonfire.Social.PostContents
  alias Bonfire.Social.Objects
  alias Bonfire.Social.Threads
  alias Bonfire.Social.Tags

  # alias Bonfire.Boundaries.Verbs
  # import Bonfire.Boundaries.Queries
  alias Bonfire.Boundaries
  # alias Bzonfire.Boundaries.Verbs

  @behaviour Bonfire.Common.ContextModule
  def schema_module, do: Message

  # @behaviour Bonfire.Federate.ActivityPub.FederationModules
  # def federation_module,
  #   do: [{"Create", "ChatMessage"}, {"Delete", "ChatMessage"}]

  @doc """
  Save a new message as a draft (without sending it).

  ## Examples

      iex> Bonfire.Messages.draft(creator, attrs)
      {:ok, %Message{}}
  """
  def draft(context, attrs) do
    with {:ok, message} <- create(attrs, to_options(context) ++ [boundary: "message"]) do
      {:ok, message}
    end
  end

  @doc """
  Sends a message to the specified recipients.

  ## Examples

      iex> Bonfire.Messages.send(me, %{post_content: %{html_body: "test message"}}, to_user_id)
  """
  def send(sender_or_context, attrs, to \\ nil)

  def send(context, attrs, to) do
    creator = current_user_required!(context)

    #   TODO: check boundaries, right now anyone can message anyone :/
    to =
      (to || e(attrs, :to_circles, nil))
      |> debug("tos")
      |> clean_tos()
      |> debug("clean_tos")
      |> Boundaries.load_pointers(current_user: creator, verb: :message)
      |> repo().maybe_preload(:character)

    # TODO: if not allowed to message, request to message?
    # |> debug("to pointers")

    if is_list(to) and to != [] do
      attrs = Map.put(attrs, :tags, to)
      # |> debug("message attrs")
      opts =
        to_options(context) ++
          [
            boundary: "message",
            verbs_to_grant: Config.get([:verbs_to_grant, :message]),
            to_circles: to || [],
            to_feeds: [inbox: to]
          ]

      # TODO: refactor to use Epics  

      with {:ok, message} <- create(attrs, opts) do
        # debug(message)
        maybe_apply(Bonfire.Social.LivePush, :notify_of_message, [
          creator,
          :message,
          message,
          to
        ])

        maybe_index_message(message, context)

        Social.maybe_federate_and_gift_wrap_activity(
          creator,
          message,
          opts
        )
      end
    else
      error("Could not find recipient.")
    end
  end

  def maybe_index_message(object, context) when is_map(object) do
    # TODO: replace with use Search Epic
    # |> debug
    # defp config(), do: Application.get_env(:bonfire_me, Users)
    if module = Extend.maybe_module(Bonfire.Posts) do
      object =
        object
        |> module.indexing_object_format()
        |> Map.put("index_type", Types.module_to_str(Message))

      maybe_apply(Bonfire.Search, :maybe_index, [object, false, context], context)
    end
  end

  # def send(creator_id, attrs, to) when is_binary(creator_id) do
  #   Bonfire.Me.Users.by_id(creator_id)
  #   ~> send(attrs, to)
  # end

  defp clean_tos(tos) when is_binary(tos), do: String.split(tos, ",") |> clean_tos()

  defp clean_tos(%{id: id}), do: id

  defp clean_tos(tos) when is_list(tos) or is_map(tos),
    do:
      tos
      |> Enum.map(fn
        {id, name} -> uid(id) || uid(name)
        other -> uid(other)
      end)
      |> filter_empty(nil)

  defp clean_tos(tos), do: tos |> filter_empty(nil)

  defp create(attrs, opts) do
    # we attempt to avoid entering the transaction as long as possible.
    changeset = changeset(:create, attrs, opts)
    # |> info
    repo().transact_with(fn -> repo().insert(changeset) end)
  end

  def changeset(:create, attrs, opts \\ []) do
    creator = current_user_required!(opts)

    attrs
    # |> debug("attrs")
    |> Message.changeset(%Message{}, ...)
    # optionally set a specific ID (e.g. from C2S ActivityPub pointer)
    |> then(fn cs ->
      if is_binary(attrs[:id]),
        do: Ecto.Changeset.put_change(cs, :id, attrs[:id]),
        else: cs
    end)
    # before  since we only want to tag `to` users, not mentions
    |> Tags.maybe_cast(attrs, creator, opts)
    # process text (must be done before Objects.cast)
    |> PostContents.cast(attrs, creator, "message", opts)
    |> maybe_spam_check(attrs, opts)
    |> Objects.cast_creator_caretaker(creator)
    # record replies & threads. preloads data that will be checked by `Acls`
    |> Threads.cast(attrs, creator, opts)
    # apply boundaries on all objects, note that ORDER MATTERS, as it uses data preloaded by `Threads` and `PostContents`
    |> Objects.cast_acl(creator, opts)
    |> Activities.put_assoc(:create, creator)
    # messages go in inbox feeds so we can easily count unread (TODO: switch to querying from inbox as well?)
    |> FeedActivities.put_feed_publishes(Keyword.get(opts, :to_feeds, []))

    # |> info()
  end

  def maybe_spam_check(changeset, attrs, context),
    do:
      maybe_apply(Bonfire.Social.Acts.AntiSpam, :check!, [changeset, attrs, context],
        fallback_return: nil
      ) || changeset

  @doc """
  Attempt to read a message by its ID.

  ## Examples

      iex> Bonfire.Messages.read(message_id, current_user: me)
      %Message{}
  """
  def read(message_id, opts) when is_binary(message_id) do
    query_filter(Message, id: message_id)
    |> Activities.read(opts)
    # load audience list
    # ~> repo().maybe_preload(activity: [tags: [:character, profile: :icon]])
    ~> Objects.maybe_preload_activity_object(opts)
    |> ok()
  end

  @doc """
  Lists messages sent by the user or sent to them, excluding replies.

  ## Options
  - `latest_in_threads` (boolean): return only the last reply in each thread (or the first message if the thread only has one)

  ## Examples

      iex> Bonfire.Messages.list(current_user)
      [%Message{}]
  """
  def list(current_user, with_user \\ nil, opts \\ [])

  def list(%{id: current_user_id} = current_user, with_user, opts)
      when is_binary(with_user) or is_list(with_user) or is_map(with_user) do
    # all messages between two people

    opts = list_options(opts)

    with_user_id = Types.uid(with_user)

    if with_user_id && with_user_id != current_user_id do
      # |> debug("list message filters")
      list_paginated(
        [
          {
            :messages_involving,
            {{with_user_id, current_user_id}, &filter/3}
          }
        ],
        current_user,
        opts
      )
    else
      list(current_user, nil, opts)
    end
  end

  def list(%{id: current_user_id} = current_user, _, opts) do
    # all current_user's message

    opts = list_options(opts)

    # Use explicit relationship filter if provided, otherwise user's DM privacy setting
    relationship_filter =
      case opts[:relationship_filter] do
        filter when filter in [:all, :followed_only, :not_followed] ->
          filter

        _ ->
          # Get user's DM privacy setting only when no explicit filter
          dm_privacy =
            Bonfire.Common.Settings.get([Bonfire.Messages, :dm_privacy], "everyone",
              current_user: current_user
            )

          case to_string(dm_privacy) do
            "followed_only" -> :followed_only
            "not_followed" -> :not_followed
            _ -> :all
          end
      end

    base_message_filters(current_user_id, relationship_filter)
    |> list_paginated(current_user, opts)
  end

  defp base_message_filters(current_user_id, :all) do
    [
      {
        :messages_involving,
        {current_user_id, &filter/3}
      }
    ]
  end

  defp base_message_filters(current_user_id, :followed_only) do
    [
      {
        :messages_involving,
        {current_user_id, &filter/3}
      },
      {
        :messages_by_relationship,
        {{current_user_id, :followed_only}, &filter/3}
      }
    ]
  end

  defp base_message_filters(current_user_id, :not_followed) do
    [
      {
        :messages_involving,
        {current_user_id, &filter/3}
      },
      {
        :messages_by_relationship,
        {{current_user_id, :not_followed}, &filter/3}
      }
    ]
  end

  def list(_current_user, _with_user, _cursor_before, _preloads), do: []

  defp list_options(opts) do
    to_options(opts)
    # TODO: only loads reply_to when displaying flat threads
    |> Keyword.put_new(
      :preload,
      if(opts[:latest_in_threads],
        do: [:posts, :with_seen],
        else: [:posts_with_reply_to, :with_seen]
      )
    )
    |> debug("opts")
  end

  defp list_paginated(
         filters,
         current_user,
         opts,
         query \\ Message
       ) do
    opts =
      to_options(opts)
      |> Keyword.put(:current_user, current_user)

    if opts[:latest_in_threads] do
      list_threads_paginated(filters, current_user, opts, query)
    else
      list_messages_paginated(filters, current_user, opts, query)
    end
  end

  defp list_messages_paginated(
         filters,
         current_user,
         opts,
         query
       ) do
    query
    # add assocs needed in timelines/feeds
    # |> proload([:activity])
    # |> debug("pre-preloads")
    |> Activities.activity_preloads(opts)
    |> query_filter(filters)
    # |> debug("message_paginated_post-preloads")
    |> Activities.as_permitted_for(current_user, [:see, :read])
    |> debug("post preloads & permissions")
    |> tap(fn query_result ->
      case query_result do
        %{edges: edges} when is_list(edges) ->
          sender_ids =
            Enum.map(edges, fn %{activity: activity} ->
              e(activity, :subject_id, "NO_SUBJECT_ID")
            end)

          IO.inspect(sender_ids, label: "ACTUAL_MESSAGE_SENDER_IDS")

        _ ->
          :ok
      end
    end)
    # |> repo().many() # return all items
    # return a page of items (reverse chronological) + pagination metadata
    |> Social.many(opts[:paginate], opts)

    # |> debug("result")
  end

  defp list_threads_paginated(
         filters,
         current_user,
         opts,
         query
       ) do
    # paginate = if opts[:paginate], do: Keyword.new(opts[:paginate]), else: opts

    # opts = opts
    # |> Keyword.put(:paginate, paginate
    #                           |> Keyword.put(:cursor_fields, [{:thread_id, :desc}])
    #   )
    # debug(opts)

    filters = filters ++ [distinct: {:threads, &Threads.filter/3}]

    query
    # add assocs needed in timelines/feeds
    # |> proload([:activity])
    # |> debug("pre-preloads")
    # |> Activities.activity_preloads(opts)
    |> query_filter(filters)
    # |> debug("message_paginated_post-preloads")
    |> Activities.as_permitted_for(current_user, [:see, :read])
    |> Threads.re_order_using_subquery(opts)
    # |> debug("post preloads & permissions")
    # |> repo().many() # return all items
    # return a page of items (reverse chronological) + pagination metadata
    |> repo().many_paginated(opts)
    # Threads query - activity preloads happen after pagination
    # |> Threads.maybe_re_order_result(opts)
    |> Activities.activity_preloads(opts)

    # |> debug("result")
  end

  def filter(:messages_involving, {user_id, _current_user_id}, query)
      when is_binary(user_id) do
    # messages between current user & someone else

    query
    |> reusable_join(:left, [root], assoc(root, :activity), as: :activity)
    |> reusable_join(:left, [activity: activity], assoc(activity, :tagged), as: :tagged)
    |> where(
      [activity: activity, tagged: tagged],
      # and activity.subject_id == ^current_user_id # shouldn't be needed if boundaries does the filtering
      tagged.tag_id == ^user_id or activity.subject_id == ^user_id

      # and tags.id == ^current_user_id # shouldn't be needed if boundaries does the filtering
    )
  end

  def filter(:messages_involving, _user_id, query) do
    # current_user's messages
    # relies only on boundaries to filter which messages to show so no other filtering needed
    query
  end

  def filter(:messages_by_relationship, {current_user_id, :followed_only}, query)
      when is_binary(current_user_id) do
    # messages from users the current user follows
    #  TODO: only select the object IDs in query instead of preloading a bunch of assocs when we just need the IDs
    # FIXME: this should filter on all thread participants, not just the sender of the last message, eg for group threads, or for messages I sent to someone
    user_ids =
      Bonfire.Social.Graph.Follows.all_objects_by_subject(current_user_id)
      |> Enum.map(&id/1)
      |> filter_empty([])

    # |> debug("FOLLOWED_USER_IDS_FOR_FILTER")

    if user_ids != [] do
      # debug("Applying followed_only filter with user IDs in WHERE clause")
      query
      |> reusable_join(:inner, [root], assoc(root, :activity), as: :activity)
      |> where([activity: activity], activity.subject_id in ^(user_ids ++ [current_user_id]))
    else
      # No followed users, return unfiltered result
      query
    end
  end

  def filter(:messages_by_relationship, {current_user_id, :not_followed}, query)
      when is_binary(current_user_id) do
    # messages from users the current user doesn't follow
    #  TODO: only select the object IDs in query instead of preloading a bunch of assocs when we just need the IDs
    # FIXME: this should filter on all thread participants, not just the sender of the last message, eg for group threads, or for messages I sent to someone
    user_ids =
      Bonfire.Social.Graph.Follows.all_objects_by_subject(current_user_id)
      |> Enum.map(&id/1)
      |> filter_empty([])

    # |> debug("user_ids for messages_by_relationship :not_followed")

    if user_ids != [] do
      query
      |> reusable_join(:inner, [root], assoc(root, :activity), as: :activity)
      |> where([activity: activity], activity.subject_id not in ^(user_ids ++ [current_user_id]))
    else
      # return unfiltered result
      query
    end
  end

  def filter(:messages_by_relationship, {_user_id, _filter_type}, query) do
    # fallback for unknown filter types
    query
  end

  @doc """
  Publishes an activity to the ActivityPub.

  ## Examples

      iex> Bonfire.Messages.ap_publish_activity(subject, verb, message)
  """
  def ap_publish_activity(subject, verb, message) do
    message =
      message
      |> repo().maybe_preload([
        :post_content,
        :media,
        :created,
        :sensitive,
        # recipients
        :tags,
        replied: [
          # thread: [:created], reply_to: [:created]
        ]
      ])
      # |> Activities.object_preload_create_activity()
      |> debug("message to federate")

    %{actor: actor, context: context, to: to, reply_to: reply_to, recipients: recipients} =
      ap_publish_prepare_metadata(subject, verb, message)

    # object = %{
    #   # "ChatMessage", # TODO: use ChatMessage with peers that support it?
    #   "type" => "Note",
    #   "actor" => actor.ap_id,
    #   "name" => e(message, :post_content, :name, nil),
    #   "summary" => e(message, :post_content, :summary, nil),
    #   "content" => Text.maybe_markdown_to_html(e(message, :post_content, :html_body, nil)),
    #   "to" => to,
    #   "context" => context,
    #   "inReplyTo" => reply_to,
    #   "tag" =>
    #     Enum.map(recipients, fn actor ->
    #       %{
    #         "href" => actor.ap_id,
    #         "name" => actor.username,
    #         "type" => "Mention"
    #       }
    #     end)
    # }

    object =
      PostContents.ap_prepare_object_note(
        subject,
        verb,
        message,
        actor,
        recipients,
        context,
        reply_to
      )
      |> Map.put("to", to)

    params = %{
      actor: actor,
      context: context,
      object: object,
      to: to,
      pointer: uid(message)
    }

    if verb == :edit, do: ActivityPub.update(params), else: ActivityPub.create(params)
  end

  def ap_publish_prepare_metadata(subject, _verb, message) do
    # TODO: extensible
    recipient_types = [Bonfire.Data.Identity.User.__pointers__(:table_id)]

    recipients =
      Enum.filter(e(message, :tags, []) |> debug("taggs"), fn tag ->
        # FIXME: this means that any tagged user will receive the message, which may be a problem if the UI allows @ mentioning or otherwise tagging users for messages without the intention of sending them a message
        tag.table_id in recipient_types
      end)
      |> Enum.map(fn pointer ->
        ActivityPub.Actor.get_cached!(pointer: pointer)
      end)
      |> filter_empty([])

    to =
      Enum.map(recipients, fn %{ap_id: ap_id} -> ap_id end)
      |> debug("tooo")

    context = e(message, :replied, :thread, nil) || e(message, :replied, :thread_id, nil)
    context = if context, do: Threads.ap_prepare(context)

    reply_to = e(message, :replied, :reply_to, nil) || e(message, :replied, :reply_to_id, nil)
    reply_to = if reply_to, do: Threads.ap_prepare(reply_to)

    {:ok, actor} = ActivityPub.Actor.get_cached(pointer: subject)

    %{actor: actor, context: context, to: to, reply_to: reply_to, recipients: recipients}
  end

  # @doc """
  # Receives an activity from ActivityPub.

  # ## Examples

  #     iex> Bonfire.Messages.ap_receive_activity(creator, activity, object)
  # """
  # def ap_receive_activity(creator, activity, object) do
  #   with {:ok, messaged} <- Bonfire.Me.Users.by_ap_id(hd(activity.data["to"])) do
  #     # TODO: refactor to use Bonfire.Social.PostContents.ap_receive_attrs_prepare
  #     attrs = %{
  #       to_circles: [messaged.id],
  #       post_content: %{html_body: object.data["content"]}
  #     }

  #     Bonfire.Messages.send(creator, attrs)
  #   end
  # end
end
