# frozen_string_literal: true

class Rogare::Commands::Novel
  extend Rogare::Command
  include Rogare::Utilities

  command 'novel'
  usage [
    '`!%` - Show your novel(s).',
    '`!% new [name...]` - Start a new novel. ',
    '`!% ID` - Show info about any novel. ' \
      'In the following sub commands, omitting `ID` will match your latest.',
    '`!% [ID] rename [name...]` - Rename your novel.',
    '`!% [ID] finish` and `unfinish` - Set your novel’s done status.',
    # '`!% [ID] stats` - Show detailed wordcount stats about your novel. Will PM you.',
    '`!% [ID] goal new [<number> words] [<number> days] [(no)repeat] [start <date>] [name "<name>"]` '\
      '- Add a new word goal to the novel.',
    '`!% [ID] goal edit [same as above]` or `!% [ID] goal edit <letter> [...]` '\
      '- Edit a goal. If `<letter>` is omitted, guesses.',
    '`!% [ID] goal remove <letter>` ' \
      '- Remove the goal from the novel. If `<letter>` is omitted, guesses.',
    "\nFor example, a revolving weekly goal of 5000 words would be set up with: " \
      '`!% goal new 5k words 7 days repeat start monday`.'
  ] # TODO: nano goals rather than nano novels
  handle_help

  match_command /new\s+(.+)/, method: :create_novel
  match_command /new/, method: :help_message

  match_command /(\d+)\s+rename\s+(.+)/, method: :rename_novel
  match_command /()rename\s+(.+)/, method: :rename_novel

  match_command /(\d+)\s+goal\s+new\s+(.+)/, method: :new_goal
  match_command /()goal\s+new\s+(.+)/, method: :new_goal

  match_command /(\d+)\s+goal\s+edit\s+(.+)/, method: :edit_goal
  match_command /()goal\s+edit\s+(.+)/, method: :edit_goal

  match_command /(\d+)\s+goal\s+(?:remove|rm)(?:\s+([a-z]+))?/, method: :remove_goal
  match_command /()goal\s+(?:remove|rm)(?:\s+([a-z]+))?/, method: :remove_goal

  match_command /(\d+)\s+goal/, method: :show_novel
  match_command /(\d+)\s+goal\s+(.*)/, method: :help_message
  match_command /goal\s+(.*)/, method: :help_message

  match_command /(\d+)\s+finish/, method: :finish_novel
  match_command /finish\s+(\d+)/, method: :finish_novel
  match_command /()finish/, method: :finish_novel

  match_command /(\d+)\s+unfinish/, method: :unfinish_novel
  match_command /unfinish\s+(\d+)/, method: :unfinish_novel
  match_command /()unfinish/, method: :unfinish_novel

  # match_command /(\d+)\s+stats\s+(.+)/, method: :statsify_novel
  # match_command /()stats\s+(.+)/, method: :statsify_novel

  match_command /(\d+)/, method: :show_novel
  match_empty :show_novels

  def show_novels(m)
    novels = m.user.novels_dataset.reverse(:started).all

    m.reply(novels.map { |nov| format_novel nov, true }.join("\n").strip)
  end

  def show_novel(m, id)
    novel = Novel[id]

    return m.reply 'No such novel' unless novel

    m.reply format_novel(novel)
  end

  def create_novel(m, name)
    novel = Novel.new(name: name.strip)
    m.user.add_novel novel

    m.reply "New novel created: #{novel.id}."
  end

  def rename_novel(m, id, name)
    novel = m.user.load_novel id

    return m.reply 'No such novel' unless novel

    novel.name = name.strip
    novel.save
    m.reply format_novel(novel)
  end

  def parse_goal(line)
    parser = GoalTermsParser.new
    tree = parser.parse line.strip.downcase

    raise "Bad input: #{parser.failure_reason}" unless tree

    tree.value
  end

  def new_goal(m, id, line)
    novel = m.user.load_novel id
    tz = m.user.timezone

    return m.reply 'No such novel' unless novel

    begin
      goal = parse_goal line
      goal.default_start!
    rescue StandardError => e
      return m.reply e
    end

    return m.reply 'I need at least a word count' unless goal.words&.positive?

    goal = Goal.new({
      words: goal.words,
      name: goal.name,
      start: goal.start(tz),
      finish: goal.finish(tz),
      repeat: goal.repeat,
      curve: goal.curve
    }.compact)
    novel.add_goal goal
    m.reply format_novel(novel)
  end

  def edit_goal(m, id, line)
    novel = m.user.load_novel id
    tz = m.user.timezone

    return m.reply 'No such novel' unless novel

    begin
      goal = parse_goal line
    rescue StandardError => e
      return m.reply e
    end

    current = novel.current_goal(goal.offset || 0)

    current.words = goal.words if goal.words
    current.name = goal.name if goal.name
    current.start = goal.start(tz) if goal.start
    current.finish = goal.finish(tz) if goal.finish(tz)
    current.repeat = goal.repeat if goal.repeat
    current.curve = goal.curve if goal.curve

    current.name = nil if goal.name == ''
    current.finish = nil if goal.days&.zero?

    current.save

    m.reply format_novel(novel)
  end

  def remove_goal(m, id, letter = nil)
    novel = m.user.load_novel id

    return m.reply 'No such novel' unless novel

    offset = letter ? (GoalTerms.letter_to_i(letter) - 1) : 0
    goal = novel.current_goal offset
    goal.removed = Time.now
    goal.save

    m.reply format_novel(novel)
  end

  def finish_novel(m, id)
    novel = m.user.load_novel id

    return m.reply 'No such novel' unless novel
    return m.reply 'Already marked done' if novel[:finished]

    novel.finished = true
    novel.save

    m.reply format_novel(novel)
  end

  def unfinish_novel(m, id)
    novel = m.user.load_novel id

    return m.reply 'No such novel' unless novel
    return m.reply 'Not marked done' unless novel[:finished]

    novel.finished = false
    novel.save
    m.reply format_novel(novel)
  end

  def format_goal(goal, offset = nil)
    goal_words = goal.format_words
    wc = goal.wordcount

    letter = if offset
               goal_words = goal_words.sub('goal', '').strip
               offset == :past ? 'past:' : "#{GoalTerms.offset_to_s(offset)}:"
             end.to_s

    details = [
      ("(“#{encode_entities(goal.name)}”)" unless goal.name.nil? || goal.name.empty?),
      "**#{goal_words}**",
      ("#{wc} written" unless wc.zero?),
      "starting _#{datef(goal.start)}_",
      ("ending _#{datef(goal.finish)}_" if goal.finish),
      ('repeating' if goal.repeat),
      ("#{goal.curve} curve" if goal.curve != 'linear')
    ].compact.join(', ')

    # strike if goal is achieved before finish line
    details = "~~#{details}~~ (done! 🎉)" if goal.done? && !goal.over?

    "#{letter} #{details}".strip
  end

  def format_novel(novel, own = false)
    goals = novel.current_goals.all
    past_goals = novel.past_goals.all
    words = novel.wordcount

    icon = novel.finished ? '📘' : '📖'
    byline = (" by #{novel.user.nixnotif}" unless own)
    title = "#{novel.id}. “**#{encode_entities(novel.name || 'Untitled')}**”#{byline}."
    details = [
      "Started _#{datef(novel.started)}_",
      ("**#{words}** words" if words.positive?),
      (unless novel.finished
         if goals.empty?
           nil
         elsif goals.length == 1
           format_goal goals.first
         else
           "**#{goals.length}** current/future goals:"
         end
       end),
      ('done' if novel.finished)
    ].compact.join(', ')

    goals = if goals.length > 1
              "\n" + goals.map.with_index { |goal, i| format_goal(goal, i) }.join("\n") + "\n"
            end.to_s

    if past_goals.length == 1
      past_goals = format_goal(past_goals.first, :past) + "\n"
    elsif past_goals.length > 1
      more_goals = past_goals.length - 1
      more_goals = nil if more_goals.zero?
      past_goals = "#{format_goal(past_goals.first, :past)}\n" +
                   ("…with **#{more_goals}** more past goal#{more_goals > 1 ? 's' : ''}.\n" if more_goals)
    else
      past_goals = nil
    end

    "#{icon} #{title} #{details} #{goals}#{past_goals}"
  end
end
