defmodule Pleroma.Web.OAuth.Token.Response do
  @moduledoc false

  alias Pleroma.User
  alias Pleroma.Web.OAuth.Token.Utils

  @expires_in Pleroma.Config.get([:oauth2, :token_expires_in], 600)

  @doc false
  def build(%User{} = user, token, opts \\ %{}) do
    %{
      token_type: "Bearer",
      access_token: token.token,
      refresh_token: token.refresh_token,
      expires_in: @expires_in,
      scope: Enum.join(token.scopes, " "),
      me: user.ap_id
    }
    |> Map.merge(opts)
  end

  def build_for_client_credentials(token) do
    %{
      token_type: "Bearer",
      access_token: token.token,
      refresh_token: token.refresh_token,
      created_at: Utils.format_created_at(token),
      expires_in: @expires_in,
      scope: Enum.join(token.scopes, " ")
    }
  end
end
