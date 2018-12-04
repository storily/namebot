# frozen_string_literal: true

class Rogare::Plugins::Wordcount
  extend Rogare::Plugin
  extend Memoist

  command 'wc'
  aliases 'count'
  usage [
    '`!%`, or: `!% <nanoname>`, or: `!% <@nick>` (to see others’ counts)',
    '`!% set <words>` or `!% add <words>` - Set or increment your word count.',
    '`!% add <words> to <novel ID>` - Set the word count for a particular novel.',
    'To register your nano name against your discord user: `!my nano <nanoname>`',
    'To set your goal: `!novel goal set <count>`. To set your timezone: `!my tz <timezone>`.'
  ]
  handle_help

  def get_today(name)
    res = Typhoeus.get "https://nanowrimo.org/participants/#{name}/stats"
    return unless res.code == 200

    doc = Nokogiri::HTML res.body
    doc.at_css('#novel_stats .stat:nth-child(2) .value').content.gsub(/[,\s]/, '').to_i
  end

  def get_count(name)
    res = Typhoeus.get "https://nanowrimo.org/wordcount_api/wc/#{name}"
    return unless res.code == 200

    doc = Nokogiri::XML(res.body)
    return unless doc.css('error').empty?

    doc.at_css('user_wordcount').content.to_i
  end

  match_command /set\s+(\d+)(?:\s+to\s+(\d+))/, method: :set_count
  match_command /add\s+(\d+)(?:\s+to\s+(\d+))/, method: :add_count
  match_command /(.+)/
  match_empty :own_count

  def own_count(m)
    get_counts(m, [m.user.mid])
  end

  def set_count(m, words, id = '')
    user = m.user.to_db
    novel = Rogare::Data.load_novel user, id

    return m.reply 'No such novel' if id && !novel
    return m.reply 'You don’t have a novel yet' unless novel
    return m.reply 'Can’t set wordcount of a finished novel' if novel[:finished]

    # return m.reply 'Can’t set wordcount of a nano/camp novel (yet)' if %w[nano camp].include? novel[:type]

    words = words.strip.to_i
    return m.reply "You're trying to set wc to 0… really? Not doing that." if words.zero?

    Rogare::Data.novels.where(id: novel[:id]).update(temp_count: words)
    own_count(m)
  end

  def add_count(m, words, id = '')
    user = m.user.to_db
    novel = Rogare::Data.load_novel user, id

    return m.reply 'No such novel' if id && !novel
    return m.reply 'You don’t have a novel yet' unless novel
    return m.reply 'Can’t set wordcount of a finished novel' if novel[:finished]

    # return m.reply 'Can’t set wordcount of a nano/camp novel (yet)' if %w[nano camp].include? novel[:type]

    words = words.strip.to_i

    Rogare::Data.novels.where(id: novel[:id]).update(temp_count: novel[:temp_count] + words)
    own_count(m)
  end

  def execute(m, param = '', opts = {})
    names = []

    param.strip.split.each do |p|
      names << p.downcase.to_sym
    end
    names << m.user.mid if names.empty?
    names.uniq!

    get_counts(m, names, opts)
  end

  def get_counts(m, names, opts = {})
    names.map! do |name|
      # Exact match from @mention / mid
      if /^<@!?\d+>$/.match?(name)
        du = Rogare.from_discord_mid(name)
        next Rogare::Data.get_nano_user(du.inner) if du
      end

      # Case-insensitive match from nick
      from_nick = Rogare::Data.users.where { nick =~ /^#{name}$/i }.first
      next from_nick[:nano_user] if from_nick && from_nick[:nano_user]

      # Otherwise just assume nano name == given name
      name
    end

    counts = names.compact.map do |name|
      user = Rogare::Data.users.where(nano_user: name.to_s).first
      tz = TZInfo::Timezone.get(user[:tz] || Rogare.tz)
      now = tz.local_to_utc(tz.now)
      timediff = now - Rogare::Data.first_of(now.month, tz)

      if user
        novel = Rogare::Data.ensure_novel(user[:discord_id])
        unless novel
          m.reply "#{name} has no current novel"
          next
        end
      end

      day_secs = 60 * 60 * 24
      month_days = Date.new(now.year, now.month, -1).day
      month_secs = day_secs * month_days

      nth = (timediff / day_secs).ceil
      goal = novel[:goal] if user && !goal
      goal = 50_000 if goal.nil? || goal == 0.0
      goal = goal.to_f

      goal_live = ((goal / month_secs) * timediff).round
      goal_today = (goal / 30 * nth).round

      count = 0
      today = 0

      if user[:id] == 10 # tamgar sets their count in their nick
        count = user[:nick].split(/[\[\]]/).last.to_i
      elsif novel && novel[:temp_count].positive?
        # TODO: proper counts
        count = novel[:temp_count]
      elsif novel[:type] == 'nano' # TODO: camp
        count = get_count(name)
        next { name: name, count: nil } if count.nil?

        today = get_today(name)
      end

      diff_live = goal_live - count
      diff_today = goal_today - count

      {
        name: name.to_s,
        count: count,
        percent: (100.0 * count / goal).round(1),
        today: today,
        diff: diff_today,
        live: diff_live,
        goal: goal
      }
    end

    return counts if opts[:return]

    if counts.count == 1
      present_one m, counts.first
    else
      m.reply counts.map { |c| format c }.join(', ')
    end
  end

  def format(data)
    "#{Rogare.nixnotif(data[:name])}: #{data[:count]} (#{[
      "#{data[:percent]}%",
      ("today: #{data[:today]}" if data[:today]),
      if data[:diff].zero?
        'up to date'
      elsif data[:diff].positive?
        "#{data[:diff]} behind"
      else
        "#{data[:diff].abs} ahead"
      end,
      if data[:live].zero?
        'up to live'
      elsif data[:live].positive?
        "#{data[:live]} behind live"
      else
        "#{data[:live].abs} ahead live"
      end,
      (Rogare::Data.goal_format data[:goal] if data[:goal] != 50_000)
    ].compact.join(', ')})"
  end

  def present_one(m, data)
    logs data.inspect

    return m.reply "#{data[:name]}: user does not exist or has no current novel" if data[:count].nil?

    if data[:count] > 100_000 && rand > 0.5
      m.reply "Content Warning: #{%w[Astonishing Wondrous Beffudling Shocking Monstrous].sample} Wordcount"
      sleep 1
    end

    m.reply format data
  end
end
