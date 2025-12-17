if Application.compile_env(:bonfire_api_graphql, :modularity) != :disabled do
  defmodule Bonfire.Messages.Web.MastoConversationController do
    @moduledoc "Mastodon-compatible Conversations (DM threads) endpoints"

    use Bonfire.UI.Common.Web, :controller

    alias Bonfire.Messages.API.GraphQLMasto.Adapter

    def index(conn, params), do: Adapter.conversations(params, conn)

    def mark_read(conn, params), do: Adapter.mark_conversation_read(params, conn)
  end
end
