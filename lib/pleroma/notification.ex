# Pleroma: A lightweight social networking server
# Copyright © 2017-2019 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Notification do
  use Ecto.Schema

  alias Ecto.Multi
  alias Pleroma.Activity
  alias Pleroma.Marker
  alias Pleroma.Notification
  alias Pleroma.Object
  alias Pleroma.Pagination
  alias Pleroma.Repo
  alias Pleroma.User
  alias Pleroma.Web.CommonAPI.Utils
  alias Pleroma.Web.Push
  alias Pleroma.Web.Streamer

  import Ecto.Query
  import Ecto.Changeset
  require Logger

  @type t :: %__MODULE__{}

  schema "notifications" do
    field(:seen, :boolean, default: false)
    belongs_to(:user, User, type: FlakeId.Ecto.CompatType)
    belongs_to(:activity, Activity, type: FlakeId.Ecto.CompatType)

    timestamps()
  end

  def changeset(%Notification{} = notification, attrs) do
    notification
    |> cast(attrs, [:seen])
  end

  @spec notifications_info_query(User.t()) :: Ecto.Queryable.t()
  def notifications_info_query(user) do
    from(q in Pleroma.Notification,
      where: q.user_id == ^user.id,
      select: %{
        unread_count: fragment("SUM( CASE WHEN seen = false THEN 1 ELSE 0 END )"),
        last_read_id:
          type(fragment("MAX( CASE WHEN seen = true THEN id ELSE null END )"), :string)
      }
    )
  end

  def for_user_query(user, opts \\ []) do
    Notification
    |> where(user_id: ^user.id)
    |> where(
      [n, a],
      fragment(
        "? not in (SELECT ap_id FROM users WHERE deactivated = 'true')",
        a.actor
      )
    )
    |> join(:inner, [n], activity in assoc(n, :activity))
    |> join(:left, [n, a], object in Object,
      on:
        fragment(
          "(?->>'id') = COALESCE((? -> 'object'::text) ->> 'id'::text)",
          object.data,
          a.data
        )
    )
    |> preload([n, a, o], activity: {a, object: o})
    |> exclude_muted(user, opts)
    |> exclude_blocked(user)
    |> exclude_visibility(opts)
  end

  defp exclude_blocked(query, user) do
    query
    |> where([n, a], a.actor not in ^user.blocks)
    |> where(
      [n, a],
      fragment("substring(? from '.*://([^/]*)')", a.actor) not in ^user.domain_blocks
    )
  end

  defp exclude_muted(query, _, %{with_muted: true}) do
    query
  end

  defp exclude_muted(query, user, _opts) do
    query
    |> where([n, a], a.actor not in ^user.muted_notifications)
    |> join(:left, [n, a], tm in Pleroma.ThreadMute,
      on: tm.user_id == ^user.id and tm.context == fragment("?->>'context'", a.data)
    )
    |> where([n, a, o, tm], is_nil(tm.user_id))
  end

  @valid_visibilities ~w[direct unlisted public private]

  defp exclude_visibility(query, %{exclude_visibilities: visibility})
       when is_list(visibility) do
    if Enum.all?(visibility, &(&1 in @valid_visibilities)) do
      query
      |> where(
        [n, a],
        not fragment(
          "activity_visibility(?, ?, ?) = ANY (?)",
          a.actor,
          a.recipients,
          a.data,
          ^visibility
        )
      )
    else
      Logger.error("Could not exclude visibility to #{visibility}")
      query
    end
  end

  defp exclude_visibility(query, %{exclude_visibilities: visibility})
       when visibility in @valid_visibilities do
    query
    |> where(
      [n, a],
      not fragment(
        "activity_visibility(?, ?, ?) = (?)",
        a.actor,
        a.recipients,
        a.data,
        ^visibility
      )
    )
  end

  defp exclude_visibility(query, %{exclude_visibilities: visibility})
       when visibility not in @valid_visibilities do
    Logger.error("Could not exclude visibility to #{visibility}")
    query
  end

  defp exclude_visibility(query, _visibility), do: query

  def for_user(user, opts \\ %{}) do
    user
    |> for_user_query(opts)
    |> Pagination.fetch_paginated(opts)
  end

  @doc """
  Returns notifications for user received since given date.

  ## Examples

      iex> Pleroma.Notification.for_user_since(%Pleroma.User{}, ~N[2019-04-13 11:22:33])
      [%Pleroma.Notification{}, %Pleroma.Notification{}]

      iex> Pleroma.Notification.for_user_since(%Pleroma.User{}, ~N[2019-04-15 11:22:33])
      []
  """
  @spec for_user_since(Pleroma.User.t(), NaiveDateTime.t()) :: [t()]
  def for_user_since(user, date) do
    from(n in for_user_query(user),
      where: n.updated_at > ^date
    )
    |> Repo.all()
  end

  def set_read_up_to(%{id: user_id} = user, id) do
    query =
      from(
        n in Notification,
        where: n.user_id == ^user_id,
        where: n.id <= ^id,
        where: n.seen == false,
        # Ideally we would preload object and activities here
        # but Ecto does not support preloads in update_all
        select: n.id
      )

    {:ok, %{ids: {_, notification_ids}}} =
      Multi.new()
      |> Multi.update_all(:ids, query, set: [seen: true, updated_at: NaiveDateTime.utc_now()])
      |> Marker.multi_set_unread_count(user, "notifications")
      |> Repo.transaction()

    Notification
    |> where([n], n.id in ^notification_ids)
    |> join(:inner, [n], activity in assoc(n, :activity))
    |> join(:left, [n, a], object in Object,
      on:
        fragment(
          "(?->>'id') = COALESCE((? -> 'object'::text) ->> 'id'::text)",
          object.data,
          a.data
        )
    )
    |> preload([n, a, o], activity: {a, object: o})
    |> Repo.all()
  end

  @spec read_one(User.t(), String.t()) ::
          {:ok, Notification.t()} | {:error, Ecto.Changeset.t()} | nil
  def read_one(%User{} = user, notification_id) do
    with {:ok, %Notification{} = notification} <- get(user, notification_id) do
      Multi.new()
      |> Multi.update(:update, changeset(notification, %{seen: true}))
      |> Marker.multi_set_unread_count(user, "notifications")
      |> Repo.transaction()
      |> case do
        {:ok, %{update: notification}} -> {:ok, notification}
        {:error, :update, changeset, _} -> {:error, changeset}
      end
    end
  end

  def get(%{id: user_id} = _user, id) do
    query =
      from(
        n in Notification,
        where: n.id == ^id,
        join: activity in assoc(n, :activity),
        preload: [activity: activity]
      )

    notification = Repo.one(query)

    case notification do
      %{user_id: ^user_id} ->
        {:ok, notification}

      _ ->
        {:error, "Cannot get notification"}
    end
  end

  def clear(user) do
    from(n in Notification, where: n.user_id == ^user.id)
    |> Repo.delete_all()
  end

  def destroy_multiple(%{id: user_id} = _user, ids) do
    from(n in Notification,
      where: n.id in ^ids,
      where: n.user_id == ^user_id
    )
    |> Repo.delete_all()
  end

  def dismiss(%{id: user_id} = _user, id) do
    notification = Repo.get(Notification, id)

    case notification do
      %{user_id: ^user_id} ->
        Repo.delete(notification)

      _ ->
        {:error, "Cannot dismiss notification"}
    end
  end

  def create_notifications(%Activity{data: %{"to" => _, "type" => "Create"}} = activity) do
    object = Object.normalize(activity)

    unless object && object.data["type"] == "Answer" do
      notifications =
        activity
        |> get_notified_from_activity()
        |> Enum.map(&create_notification(activity, &1))

      {:ok, notifications}
    else
      {:ok, []}
    end
  end

  def create_notifications(%Activity{data: %{"to" => _, "type" => type}} = activity)
      when type in ["Like", "Announce", "Follow"] do
    notifications =
      activity
      |> get_notified_from_activity
      |> Enum.map(&create_notification(activity, &1))

    {:ok, notifications}
  end

  def create_notifications(_), do: {:ok, []}

  # TODO move to sql, too.
  def create_notification(%Activity{} = activity, %User{} = user) do
    unless skip?(activity, user) do
      {:ok, %{notification: notification}} =
        Multi.new()
        |> Multi.insert(:notification, %Notification{user_id: user.id, activity: activity})
        |> Marker.multi_set_unread_count(user, "notifications")
        |> Repo.transaction()

      ["user", "user:notification"]
      |> Streamer.stream(notification)

      Push.send(notification)
      notification
    end
  end

  def get_notified_from_activity(activity, local_only \\ true)

  def get_notified_from_activity(
        %Activity{data: %{"to" => _, "type" => type} = _data} = activity,
        local_only
      )
      when type in ["Create", "Like", "Announce", "Follow"] do
    recipients =
      []
      |> Utils.maybe_notify_to_recipients(activity)
      |> Utils.maybe_notify_mentioned_recipients(activity)
      |> Utils.maybe_notify_subscribers(activity)
      |> Enum.uniq()

    User.get_users_from_set(recipients, local_only)
  end

  def get_notified_from_activity(_, _local_only), do: []

  @spec skip?(Activity.t(), User.t()) :: boolean()
  def skip?(activity, user) do
    [
      :self,
      :followers,
      :follows,
      :non_followers,
      :non_follows,
      :recently_followed
    ]
    |> Enum.any?(&skip?(&1, activity, user))
  end

  @spec skip?(atom(), Activity.t(), User.t()) :: boolean()
  def skip?(:self, activity, user) do
    activity.data["actor"] == user.ap_id
  end

  def skip?(
        :followers,
        activity,
        %{notification_settings: %{"followers" => false}} = user
      ) do
    actor = activity.data["actor"]
    follower = User.get_cached_by_ap_id(actor)
    User.following?(follower, user)
  end

  def skip?(
        :non_followers,
        activity,
        %{notification_settings: %{"non_followers" => false}} = user
      ) do
    actor = activity.data["actor"]
    follower = User.get_cached_by_ap_id(actor)
    !User.following?(follower, user)
  end

  def skip?(:follows, activity, %{notification_settings: %{"follows" => false}} = user) do
    actor = activity.data["actor"]
    followed = User.get_cached_by_ap_id(actor)
    User.following?(user, followed)
  end

  def skip?(
        :non_follows,
        activity,
        %{notification_settings: %{"non_follows" => false}} = user
      ) do
    actor = activity.data["actor"]
    followed = User.get_cached_by_ap_id(actor)
    !User.following?(user, followed)
  end

  def skip?(:recently_followed, %{data: %{"type" => "Follow"}} = activity, user) do
    actor = activity.data["actor"]

    Notification.for_user(user)
    |> Enum.any?(fn
      %{activity: %{data: %{"type" => "Follow", "actor" => ^actor}}} -> true
      _ -> false
    end)
  end

  def skip?(_, _, _), do: false
end
