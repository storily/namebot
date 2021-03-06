# frozen_string_literal: true

require './cli'

logs '=====> Loading commands'
Dir['./commands/*.rb'].each do |p|
  name = Pathname.new(p).basename('.rb').to_s
  if ENV['COMMANDS_WHITELIST']
    next unless ENV['COMMANDS_WHITELIST'].split(',').include? name
  end

  require p
end

logs '=====> Preparing threads'

Rogare.spinoff(:goals) do
  logs '=====> Spinning up goal repeater'
  loop do
    n = Goal.need_repeating.map(&:repeat_if_needed!).length
    logs "=====> The goal repeater repeated #{n} goals! Nom nom nom" if n.positive?
    sleep 10.minutes
  end
end

if ENV['RACK_ENV'] == 'production' || ENV['DEV_LOAD_WARS']
  Rogare.spinoff(:wars) do
    sleep 3
    logs '=====> Loading wordwars from Postgres'
    wars = War.start_timers_for_existing
    logs "=====> Loaded #{wars.count} wordwars, now waiting on timers"
    wars.each(&:join)
  end
end

if ENV['RACK_ENV'] == 'production'
  Rogare.spinoff(:debug) do
    logs '=====> Preparing live debug port'
    binding.remote_pry
  end
end

Rogare.spinoff(:discord) do
  logs '=====> Starting Discord'
  Rogare.discord.run
end

Rogare.spinall!
