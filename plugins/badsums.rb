require 'time'

class Caskbot::Plugins::Badsums
  include Cinch::Plugin
  include ActionView::Helpers::DateHelper

  match 'badsums'
  @@commands = ['badsums']

  def execute(m)
    url = 'https://dl.dropboxusercontent.com/u/17915390/CaskTasting.txt'

    summary =  Typhoeus.get(url).body.split("\n")
    start_date = summary.shift.match(/(?:at\s)(.+)/)[1]
    finish_date = summary.pop.match(/(?:at\s)(.+)/)[1]

    begin
      start_date = DateTime.parse start_date
      finish_date = DateTime.parse finish_date
    rescue
      start_date = finish_date = DateTime.now
    end
    
    nfail = 0
    nnots = 0
    nbads = 0
    total = 0
    
    summary.each do |line|
      unless line[0] == ' '
        total += 1
        nfail += 1 if line =~ /download error/
        nnots += 1 if line =~ /no checksum/
        nbads += 1 if line =~ /mismatch/
      end
    end

    pfail = (nfail * 100.0 / total).round 1
    pnots = (nnots * 100.0 / total).round 1
    pbads = (nbads * 100.0 / total).round 1

    started_ago = distance_of_time_in_words_to_now start_date
    time_taken = distance_of_time_in_words start_date, finish_date

    m.reply "#{nfail} failed downloads (#{pfail}%) and #{nbads} bad checksums (#{pbads}%) - #{nnots} w/o checksum (#{pnots}%) - #{total} casks total"
    m.reply "Last check #{started_ago} ago, took #{time_taken} to complete"
    m.reply "Details at: http://bit.ly/P5ggys"
  end
end