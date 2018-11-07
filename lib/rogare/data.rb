# frozen_string_literal: true

module Rogare::Data
  class << self
    def users
      Rogare.sql[:users]
    end

    def user_seen(user)
      nick = user.nick || user.username
      discordian = users.where(discord_id: user.id).first

      return new_user(user) unless discordian
      return unless Time.now - discordian[:last_seen] > 60 || discordian[:nick] != nick

      users.where(id: discordian[:id]).update(
        last_seen: Sequel.function(:now),
        nick: nick
      )
    end

    def new_user(user)
      users.insert(
        discord_id: user.id,
        nick: user.nick || user.username,
        first_seen: Sequel.function(:now),
        last_seen: Sequel.function(:now)
      )
    end
  end
end