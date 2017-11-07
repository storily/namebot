class Rogare::Plugins::Wordwar
  include Cinch::Plugin
  extend Rogare::Help

  command 'wordwar'
  aliases 'war', 'ww'
  usage [
      '!% in [time before it starts (in minutes)] for [duration]',
      'Or: !% at [wall time e.g. 12:35] for [duration]',
      'Or even (defaulting to a 20 minute run): !% at/in [time]',
      'And then everyone should: !% join [wordwar ID]',
      'Also say !% alone to get a list of current/scheduled ones.'
  ]
  handle_help

  @@redis = Rogare.redis(3)

  match_command /join(.*)/, method: :ex_join_war
  match_command /leave(.*)/, method: :ex_leave_war
  match_command /cancel(.*)/, method: :ex_cancel_war
  match_command /(.+)/
  match_empty :ex_list_wars

  def execute(m, param)
    time, durstr = param.strip.split(/for/i).map {|p| p.strip}

    time = time.sub(/^at/i, '').strip if time.downcase.start_with? 'at'
    durstr = "20 minutes" if durstr.nil? || durstr.empty?

    timenow = Time.now

    timeat = Chronic.parse(time)
    timeat = Chronic.parse("in #{time}") if timeat.nil?
    if timeat.nil?
      m.reply "Can't parse time: #{time}"
      return
    end

    if timeat < timenow && time.to_i < 13
      # This is if someone entered 12-hour PM time,
      # and it parsed as AM time, e.g. 9:00.
      timeat += 12 * 60 * 60
    end

    if timeat < timenow
      # If time is still in the past, something is wrong
      m.reply "#{time} is in the past, what???"
      return
    end

    if timeat > timenow + 12 * 60 * 60
      m.reply "Cannot schedule more than 12 hours in the future, sorry"
      return
    end

    duration = ChronicDuration.parse("#{durstr} minutes")
    if duration.nil?
      m.reply "Can't parse duration: #{durstr}"
      return
    end

    k = self.class.store_war(m, timeat, duration)
    togo, neg = dur_display(timeat, timenow)
    dur, _ = dur_display(timeat + duration, timeat)

    if k.nil? || neg
      m.reply "Got an error, check your times and try again."
      return
    end

    m.reply "Got it! " +
      "Your new wordwar will start in #{togo} and last #{dur}. " +
      "Others can join it with: !wordwar join #{k}"

    self.class.set_war_timer(k, timeat, duration).join
  end

  def rk(*args) self.class.rk(*args) end
  def nixnotif(*args) self.class.nixnotif(*args) end
  def dur_display(*args) self.class.dur_display(*args) end
  def all_wars(*args) self.class.all_wars(*args) end

  def ex_list_wars(m)
    wars = all_wars
      .reject {|w| w[:end] < Time.now}
      .sort_by {|w| w[:start]}

    wars.each do |war|
      togo, neg = dur_display war[:start]
      others = war[:members].reject {|u| u == war[:owner]}

      m.reply [
        "#{war[:id]}: #{nixnotif war[:owner]}'s war",

        if neg
          "started #{togo} ago"
        else
          "starting in #{togo}"
        end,

        if neg
          "#{dur_display(Time.now, war[:end]).first} left"
        else
          "for #{dur_display(war[:end], war[:start]).first}"
        end,

        unless others.empty?
          "with #{others.count} others"
        end
      ].compact.join(', ')
    end

    if wars.empty?
      m.reply "No current wordwars"
    end
  end

  def ex_join_war(m, param)
    k = param.strip.to_i
    return m.reply "You need to specify the wordwar ID" if k == 0

    unless @@redis.exists rk(k, 'start')
      return m.reply "No such wordwar"
    end

    @@redis.sadd rk(k, 'members'), m.user.nick
    m.reply "You're in!"
  end

  def ex_leave_war(m, param)
    k = param.strip.to_i
    return m.reply "You need to specify the wordwar ID" if k == 0

    unless @@redis.exists rk(k, 'start')
      return m.reply "No such wordwar"
    end

    @@redis.srem rk(k, 'members'), m.user.nick
    m.reply "You're out."
  end

  def ex_cancel_war(m, param)
    k = param.strip.to_i
    return m.reply "You need to specify the wordwar ID" if k == 0

    unless @@redis.exists rk(k, 'start')
      return m.reply "No such wordwar"
    end

    self.class.erase_war k
    m.reply "Wordwar #{k} deleted."
  end

  class << self
    def set_war_timer(id, start, duration)
      Thread.new do
        info = war_info(id)
        chan = Rogare.bot.channel_list.find info[:channel]

        if chan.nil?
          puts "=====> Error: no such channel: #{info[:channel]}"
          STDOUT.flush
          next
        end

        reply = lambda {|msg| chan.send msg}

        starting = lambda {|time, extra = nil|
          members = war_info(id)[:members].join(', ')
          reply.call "Wordwar #{id} is starting #{time}! #{members}#{extra || ''}"
        }

        ending = lambda {
          members = war_info(id)[:members].join(', ')
          reply.call "Wordwar #{id} has ended! #{members}"
        }

        to_start = start - Time.now
        if to_start > 0
          # We're before the start of the war

          if to_start > 35
            # If we're at least 35 seconds before the start, we have
            # time to send a reminder. Otherwise, skip sending it.
            sleep to_start - 30
            starting.call 'in 30 seconds', ' -- Be ready: tell us your starting wordcount.'
            sleep 30
          else
            # In any case, we sleep until the beginning
            sleep to_start
          end

          starting.call 'now'
          start_war id
          sleep duration
          ending.call
          erase_war id
        else
          # We're AFTER the start of the war. Probably because the
          # bot restarted while a war was running.

          to_end = (start + duration) - Time.now
          if to_end < 0
            # We're after the END of the war, but before Redis expired
            # the keys, and also the keys were not erased manually, so
            # it must be that the war ended as the bot was restarting!
            # Oh no. That means we're probably a bit late.
            ending.call
            erase_war id
          else
            unless @@redis.exists rk(id, 'started')
              # The war is not marked as started but it is started, so
              # the bot probably restarted at the exact moment the war
              # was supposed to start. That means we're probably late.
              starting.call 'just now'
              start_war id
            end

            sleep to_end
            ending.call
            erase_war id
          end
        end
      end
    end

    def start_war(id)
      @@redis.set rk(id, 'started'), '1'
    end

    def erase_war(id)
      @@redis.keys(rk(id, '*')).each do |k|
        @@redis.persist k # transitionary
        @@redis.rename k, "archive:#{k}"
      end
    end

    def dur_display(time, now = Time.now)
      diff = time - now
      minutes = diff / 60.0
      secs = (minutes - minutes.to_i).abs * 60.0

      neg = false
      if minutes < 0
        minutes = minutes.abs
        neg = true
      end

      [if minutes >= 5
        "#{minutes.round}m"
      elsif minutes >= 1
        "#{minutes.floor}m #{secs.round}s"
      else
        "#{secs.round}s"
      end, neg]
    end

    def nixnotif(nick)
      # Insert a zero-width space as the second character of the nick
      # so that it doesn't notify that user. People using web clients
      # or desktop clients shouldn't see anything, people with terminal
      # clients may see a space, and people with bad clients may see a
      # weird box or invalid char thing.
      nick.sub(/^(.)/, "\\1\u200B")
    end

    def rk(war, sub = nil)
      ['wordwar', war, sub].compact.join ':'
    end

    def all_wars
      @@redis.keys(rk('*', 'start')).map do |k|
        k.gsub /(^wordwar:|:start$)/, ''
      end.map do |k|
        war_info k
      end
    end

    def war_info(id)
      {
        id: id,
        channel: @@redis.get(rk(id, 'channel')),
        owner: @@redis.get(rk(id, 'owner')),
        members: @@redis.smembers(rk(id, 'members')),
        start: Chronic.parse(@@redis.get(rk(id, 'start'))),
        end: Chronic.parse(@@redis.get(rk(id, 'end'))),
      }
    end

    def store_war(m, time, duration)
      # War is in the past???
      return if ((time + duration) - Time.now).to_i < 0

      k = @@redis.incr rk('count')
      @@redis.multi do
        @@redis.set rk(k, 'channel'), m.channel.to_s
        @@redis.set rk(k, 'owner'), m.user.nick
        @@redis.sadd rk(k, 'members'), m.user.nick
        @@redis.set rk(k, 'start'), "#{time}"
        @@redis.set rk(k, 'end'), "#{time + duration}"
      end
      k
    end

    def load_existing_wars
      all_wars.reject {|w| w[:end] < Time.now}.map do |war|
        set_war_timer(war[:id], war[:start], war[:end] - war[:start])
      end
    end
  end
end