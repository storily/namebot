# frozen_string_literal: true

module Rogare
  class << self
    extend Memoist

    @@boot = Time.now
    def boot
      @@boot
    end

    @@threads = []
    def spinoff(_thing, &block)
      @@threads << Thread.new(&block)
    end

    def spinall!
      require 'thwait'
      ThreadsWait.all_waits(*@@threads)
    end

    def prefix
      if ENV['RACK_ENV'] == 'production'
        '!'
      else
        '§'
      end
    end

    def tz
      ENV['TZ'] || 'Pacific/Auckland'
    end

    def game
      Game.random_text
    end

    # Extremely short-lived global cache for initial user lookups.
    # Idea is to avoid doing two lookups on the same message for seen!
    # and for passing to commands. These will occur within the same
    # second, and we want to keep the cache otherwise fresh, so two
    # messages two seconds apart should reasonably do two lookups (e.g.
    # if one mutates the user record, the next should see that.)
    # The “default” maximum of 100 entries in the cache is unlikely to
    # ever be reached (≈ 100 messages per second) and because it’s LRU,
    # will not matter anyway (traffic would need to be a lot higher, maybe
    # in the 10,000s per second, for it to do two lookups for a message.)
    @@user_cache = LruRedux::TTL::ThreadSafeCache.new(100, 1)
    def user_cache
      @@user_cache
    end

    def discord
      bot = Discordrb::Bot.new token: ENV['DISCORD_TOKEN']
      puts "This bot's discord invite URL is #{bot.invite_url}."

      if ENV['RACK_ENV'] == 'production' && ENV['LEAVE_STATUS'].nil?
        bot.ready do
          bot.update_status('online', Rogare.game, nil)
        end
      end

      bot.message do |event|
        user_cache.getset(event.author.id) do
          User.create_from_discord(event.author)
        end.seen!
      end

      if ENV['RACK_ENV'] == 'production'
        bot.member_join do |event|
          user_cache.getset(event.user.id) do
            User.create_from_discord(event.user)
          end.seen!
        end
      end

      bot
    end

    def config
      c = Hashie::Mash.new
      ENV.each { |k, v| c[k.downcase] = v }
      c
    end

    def sql
      db = Sequel.connect ENV['DATABASE_URL'], search_path: [ENV['DB_SCHEMA'] || 'public']
      db.extension :pg_array
      db.extension :pg_comment
      Sequel.extension :pg_array_ops
      db.logger = Logger.new($stdout) unless ENV['RACK_ENV'] == 'production'
      db
    end

    def from_discord_mid(mid)
      id = mid.to_s.gsub(/[^\d]/, '').to_i
      du = discord.users[id]
      return unless du

      User.create_from_discord(du)
    end

    def nixnotif(nick)
      # If we get a mentionable discord ID, lookup the user and retrieve a nick:
      if /<@!?\d+>/.match?(nick)
        du = from_discord_mid(nick)
        nick = du.nick if du
      end

      # Insert a zero-width space as the second character of the nick
      # so that it doesn't notify that user. People using web clients
      # or desktop clients shouldn't see anything, people with terminal
      # clients may see a space, and people with bad clients may see a
      # weird box or invalid char thing.
      nick&.sub(/^(.)/, "\\1\u200B")
    end

    def channel_list
      list = []

      discord.servers.each do |_id, srv|
        srv.channels.each do |chan|
          list << DiscordChannelShim.new(chan)
        end
      end

      list
    end

    # MAY RETURN AN ARRAY (if multiple chans match) so ALWAYS HANDLE THAT
    # unless you're always passing slashed chan names
    # Note that non-ID slashed names can be collided.
    def find_channel(name)
      if name.include? '/'
        sid, cid = name.split('/')

        server = discord.servers[sid.to_i]
        server ||= (discord.servers.find { |_i, s| s.name.downcase.tr(' ', '~') == sid.downcase } || [])[1]
        return unless server

        chan = server.channels.find { |c| [c.id.to_s, c.name].include? cid }
        return unless chan

        DiscordChannelShim.new chan
      else
        chans = channel_list.select { |c| c.name == name }
        if chans.count == 1
          chans.first
        elsif chans.count > 1
          chans
        end
      end
    end

    memoize :discord, :config, :nixnotif, :sql, :tz
  end
end
