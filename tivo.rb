#!/usr/bin/env ruby

load './tivo.conf'

#$debug = true

##############################################################################

PROG_VERSION = '0.0.1'

CURL = "curl --insecure --cookie-jar /dev/null --netrc --digest"

# number of spaces between command (with aliases) and description
GENERAL_HELP_PADDING = 2

$progname = File.basename($0)

require 'rexml/document'
require 'ostruct'
require 'open-uri'
require 'tmpdir'
require 'fileutils'
require 'progressbar'
require 'optparse'
require 'term/ansicolor'

class String
  include Term::ANSIColor

  # TODO: this is not very portable, and will default to 0
  @@term_cols = `stty size`.split[1].to_i

  alias_method :orig_center, :center
  def center (integer = @@term_cols)
    orig_center(integer)
  end
end



require 'yaml'

include REXML

# SuperArgv is an iterator only replacement for ARGV.
# When ARGV is not empty, SuperArgv iterates over ARGV.
# When ARGV is empty, SuperArgv uses each line of stdin as an argument.
class SuperArgv
  include Enumerable

  def each
    if ARGV.empty?
      $stdin.each_line do |a|
        next if /\A\s*\Z/ === a.chomp!
        yield a
      end
    else
      ARGV.each do |a|
        yield a
      end
    end
  end
end

SUPER_ARGV = SuperArgv.new

module TiVo
  class Container
    attr_reader :title, :last_change_date, :items

    def self.now_playing
      dir = Dir.tmpdir + "/tivo"
      FileUtils.mkdir_p dir
      now_playing_file  = dir + "/now_playing.xml"
        if not File.exists?(now_playing_file) \
          or (not $debug and Time.now - File::mtime(now_playing_file) >= 30*60)
          $stderr.puts "time to download again"
          url = "https://#{TIVO_ADDRESS}/TiVoConnect?Command=QueryContainer&Container=%2FNowPlaying&Recurse=Yes"
          open("|#{CURL} '#{url}'") do |input|
            open(now_playing_file, "w") do |output|
              output.write(input.read)
            end
          end
        end
      return open(now_playing_file) do |io|
        TiVo::Container.new(io)
      end
    end

    def initialize (io)
      case io
      when IO
        parse(io)
      when String
      end
    end

    def parse (io)

      @items = Array.new
      doc = Document.new(io)

      at = proc { |path| tmp=doc.root.elements[path]; tmp.nil? ? nil : tmp.text }

      @title = at['/TiVoContainer/Details/Title']
      @last_change_date = Time.at(at['/TiVoContainer/Details/LastChangeDate'].hex)

      @total_items = at['/TiVoContainer/Details/TotalItems'].to_i
      item_start = at['/TiVoContainer/ItemStart'].to_i
      item_count = at['/TiVoContainer/ItemCount'].to_i
      unless item_count - item_start == @total_items
        # if this becomes a problem, place additional calls for more items
        fail 'did not receive a full set of items'
      end

      doc.root.elements.each('/TiVoContainer/Item') do |ele|
        @items << Item.new(ele)
      end

      @items
    end
  end

  class Item
    attr_reader :program_id, :title, :episode_title, :episode_number, :links,
      :capture_date, :description, :duration, :source, :in_progress

    def initialize (ele)
      at = proc { |path| tmp=ele.elements[path]; tmp.nil? ? nil : tmp.text }
      @program_id = at['Details/ProgramId']
      @title = at['Details/Title']
      begin @episode_title = at['Details/EpisodeTitle']; rescue; end
      begin @episode_number = at['Details/EpisodeNumber'].to_i; rescue; end
      @capture_date = Time.at(at['Details/CaptureDate'].hex)
      begin
        @description = at['Details/Description']
        @description.sub!(' Copyright Tribune Media Services, Inc.', '')
      rescue; end
      @duration = at['Details/Duration'].to_i  # duration is in ms
      @content_type = at['Details/ContentType']

      @in_progress = false
      tmp = at['Details/InProgress']
      @in_progress = true if tmp and tmp == 'Yes'

      @links = OpenStruct.new
      @links.content = OpenStruct.new
      @links.content.url = at['Links/Content/Url']
      @links.content.content_type = at['Links/Content/ContentType']
      @links.content.available = true  # assume it is available
      tmp = at['Links/Content/Available']
      @links.content.available = false if tmp and tmp == 'No'
      @links.video_details = OpenStruct.new
      @links.video_details.url = at['Links/TiVoVideoDetails/Url']
      #@links.video_details.content_type = at['Links/TiVoVideoDetails/ContentType']

      @source = OpenStruct.new
      @source.channel = at['Details/SourceChannel'].to_i
      @source.size = at['Details/SourceSize'].to_i
      @source.format = at['Details/SourceFormat']
      @source.station = at['Details/SourceStation']
    end

    def video_details
      @video_details ||= VideoDetails.new(@links.video_details.url)
      @video_details
    end
  end

  class VideoDetails
    attr_accessor :time, :duration, :program, 
      :channel, :tv_rating, :recording_quality,
      :start_time, :stop_time, :expiration_time

    def initialize (url)
      id = /id=(\d+)/.match(url)[1]
      fname = Dir.tmpdir + "/tivo/#{id}.xml"
      unless File.exists?(fname)
        system "#{CURL} --silent #{url} -o #{fname}"
        unless $?.success?
          raise RuntimeError, 'failed to download video details'
        end
      end

      showing = 'vActualShowing'
      #showing = 'showing'

      doc = open(fname) do |io|
        Document.new(io.read)
      end

      at = proc do |path|
        begin
          doc.elements["/TvBusMarshalledStruct:TvBusEnvelope/#{showing}/#{path}"].text
        rescue
          $stderr.puts "failed to get path: #{path}"
          nil
        end
      end


      at_array = proc do |path|
        (doc.elements["/TvBusMarshalledStruct:TvBusEnvelope/#{showing}/element/program/#{path}"] || Array.new).map { |e| e.text }
      end

      @time = Time.parse(at['element/time'])
      @duration = at['element/duration']

      @program = OpenStruct.new
      @program.actors = at_array['vActor']
      @program.advisory = at_array['vAdvisory']
      @program.choreographers = at_array['vChoreographer']
      @program.color_code = at['element/program/colorCode']
      @program.country = at['element/program/country']
      @program.description = at['element/program/description'] and \
        @program.description.sub!(' Copyright Tribune Media Services, Inc.', '')
      @program.directors = at_array['vDirector']
      # TODO: when NA, should episode_number be 0 or nil?
      #@program.episode_number = tmp.nil? ? nil : tmp.to_i
      @program.episode_number = at['element/program/episodeNumber'].to_i
      @program.exec_producers = at_array['vExecProducer']
      @program.genres = at_array['vProgramGenre']
      @program.guest_stars = at_array['vGuestStar']
      @program.hosts = at_array['Host']
      @program.is_episode = at['element/program/isEpisode'] == 'true' ? true : false

      begin
        @program.original_air_date = Time.parse(at['element/program/originalAirDate'])
      rescue; end

      # TODO: should struct still have entries even if it is not a movie?
      @program.movie_run_time = at['element/program/movieRunTime']
      @program.movie_year = at['element/program/movieYear'].to_i
      # TODO: determine mpaa rating format
      @program.mpaa_rating = at['element/program/mpaaRating']

      @program.producers = at_array['vProducer']


      # series
      @program.series = OpenStruct.new
      @program.series.is_episodic = at['element/program/series/isEpisodic'] == 'true' ? true : false
      @program.series.genres = at_array['series/vSeriesGenre']
      @program.series.title = at['element/program/series/seriesTitle']


      begin
        # TODO: is subtracting 1 proper?
        @program.star_rating = doc.elements['/TvBusMarshalledStruct:TvBusEnvelope/#{showing}/element/program/starRating'].attributes['value'].to_i - 1
      rescue; end

      begin
        @program.show_type = at['element/program/showType'].downcase!.to_sym
      rescue; end

      @program.title = at['element/program/title']
      @program.writers = at_array['vWriter']

      # end of program

      # channel
      @channel = OpenStruct.new
      @channel.display_major_number = at['element/channel/displayMajorNumber'].to_i
      @channel.callsign = at['element/channel/callsign']

      # TODO: store element value, text, or symbol?
      @tv_rating = at['element/tvRating']

      # ignoring bookmark

      # TODO: store numeric value?
      @recording_quality = doc.elements['/TvBusMarshalledStruct:TvBusEnvelope/recordingQuality'].text.downcase!.to_sym

      @start_time = Time.parse(doc.elements['/TvBusMarshalledStruct:TvBusEnvelope/startTime'].text)
      @stop_time = Time.parse(doc.elements['/TvBusMarshalledStruct:TvBusEnvelope/stopTime'].text)

      #ignoring bitstream info

      @expiration_time = Time.parse(doc.elements['/TvBusMarshalledStruct:TvBusEnvelope/expirationTime'].text)
    end
  end
end # module TiVo

def list
  TiVo::Container.now_playing.items.each do |item|
    if item.episode_title
      puts "#{item.program_id} | #{item.title} - #{item.episode_title}"
    else
      puts "#{item.program_id} | #{item.title}"
    end
  end
end

def get
  options = OpenStruct.new
  OptionParser.new do |opts|
    opts.banner = <<-EOF
usage: #$progname get [options] program_ids...

    Also reads from stdin.

EOF

    opts.on('-d', '--dump', 'Dump stream to stdout') do
      options.dump = true
    end
  end.parse!

  sanitize = proc do |filename|
    retval = filename.gsub(/\s/, '_')#.gsub("'", '\'')
    retval.gsub!(/[:?]/, '_')
    retval
  end

  items = TiVo::Container.now_playing.items
  SUPER_ARGV.each do |program_id|
    item = items.find { |item| item.program_id == program_id }
    filename = if item.episode_title
                 "#{item.title} - #{item.episode_title}.mpg"
               else
                 "#{item.title}.mpg"
               end

    # the following block will include the episode number, if given
    # as well as rename any existing files
    if item.episode_title and not item.episode_number.zero?
      f = "#{item.title} - (#{'%03d'%item.episode_number}) #{item.episode_title}.mpg"
      if File.exist?(sanitize[filename])
        FileUtils.mv(sanitize[filename], sanitize[f], :verbose => true)
      end
      filename = f
    end

    #p filename.gsub(' ', '_')
    #exit!

    filename = filename.gsub(/\s/, '_')#.gsub("'", '\'')
    filename.gsub!(/[:?]/, '_')
    filename = sanitize[filename]
    $stderr.puts "getting " + filename
    if File.exists?(filename)
      $stderr.puts "cowardly refusing to overwrite #{filename}"
      next
    end
    unless item.links.content.available
      $stderr.puts "#{filename} is not available"
      next
    end
    if options.dump
      system "#{CURL} --silent \"#{item.links.content.url}\" | tivodecode -- -"
      # TODO: exiting after dumping means only the first file will be downloaded
      exit $?.exitstatus
    else

      system "#{CURL} --silent \"#{item.links.content.url}\" | pv --size #{item.source.size} | tivodecode --out \"#{filename}.part\" -- -"
      #system "#{CURL} --silent \"#{item.links.content.url}\" | pv -cN source --wait --size #{item.source.size} | tivodecode -- - | pv --wait -cN tivodecode > " + filename.gsub(';', '\;')
      if $?.success?
        FileUtils.mv filename + '.part', filename
      else
        #fail 'error getting file'
        $stderr.puts 'error getting file'
      end

#      download_thread = Thread.new do
#        system "#{CURL} --silent \"#{item.links.content.url}\" | tivodecode -o \"#{filename}\" -- -"
#      end
#      sleep 5  # wait for download to start
#      # this is not ideal, but curl does not seem to know the download size
#      pbar = ProgressBar.new(filename, item.source.size)
#      while download_thread.alive?
#        current_size = File.size(filename)
#        # ProgressBar#set chokes if value is greater than total
#        pbar.set current_size unless current_size > item.source.size
#        sleep 1
#      end
#      if $?.success?
#        pbar.finish
#      else
#        pbar.halt
#        $stderr.puts "what went wrong?"
#      end

    end
  end
end

def details
  options = OpenStruct.new
  OptionParser.new do |opts|
    opts.banner = <<-EOF
usage: #$progname details [options] program_ids...

    Also reads from stdin.

EOF

    opts.on("-v", "--[no-]verbose", "Run verbosely") do |v|
      options.verbose = v
    end
    opts.on("-h", "--human-readable", "Controls duration format") do |h|
      options.human_readable = h
    end
    opts.on("-a", "--all", "Show all programs") do |a|
      options.all = a
    end
  end.parse!

  pretty_duration = proc do |ms|
    minutes = ms / 60000
    hours = 0
    while minutes >= 60
      minutes -= 60
      hours += 1
    end
    unless options.human_readable
      return "%0d:%02d" % [hours, minutes]
    else
      case hours
      when 0
        return "#{minutes} minutes"
      when 1
        if minutes == 0
          return "1 hour"
        else
          return "1 hour and #{minutes} minutes"
        end
      else
        if minutes == 0
          return "#{hours} hours"
        else
          return "#{hours} hours and #{minutes} minutes"
        end
      end # case
    end # if
  end # proc

  format_name_list = proc do |ary|
    ary.map do |guest|
      parts = guest.split('|')
      "#{parts[1]} #{parts[0]}"
    end.join(', ')
  end

  items = TiVo::Container.now_playing.items
  list = if options.all
           items.collect{|item|item.program_id}
         else
           SUPER_ARGV
         end
  list.each do |program_id|
    item = items.find { |item| item.program_id == program_id }
    puts "-- #{item.program_id} --".center.green
    puts "Title        | " + item.title
    puts "Episode Title| " + item.episode_title if item.episode_title
    puts "Description  | " + (item.description || "")
    puts "Capture Date | " + item.capture_date.to_s
    puts "Duration     | " + pretty_duration.call(item.duration)
    puts "Channel      | #{item.source.station} @ #{item.source.channel}"
    puts "Available    | #{item.links.content.available}" if
      not item.links.content.available or options.verbose
    #puts "Format: " + item.source.format
    puts "Size: " + item.source.size.to_s if options.verbose

    next unless options.verbose

    puts '==='.center.yellow

    #puts "Star Rating  | " + ('*' * (item.video_details.program.star_rating||0))
    puts "Star Rating  | " + ('*' * item.video_details.program.star_rating) if item.video_details.program.star_rating
    puts "TV Rating    | " + item.video_details.tv_rating if item.video_details.tv_rating 

    # TODO: consider is_episode and series.is_episodic
    if item.video_details.program.series.is_episodic
      #fail 'epi number is 0' if item.video_details.program.episode_number == 0
      puts "Episode Num  | " + item.video_details.program.episode_number.to_s
      puts "Orig Air Date| " + item.video_details.program.original_air_date.to_s
    else
      fail "reconsider is_episodic" if item.video_details.program.episode_number != 0
      puts "Movie Year   | " + item.video_details.program.movie_year.to_s
      puts "MPAA Rating  | " + item.video_details.program.mpaa_rating
    end

    puts "Actors       | " + format_name_list.call(item.video_details.program.actors)
    puts "Guest Stars  | " + format_name_list.call(item.video_details.program.guest_stars)
    puts "Directors    | " + format_name_list.call(item.video_details.program.directors)
    puts "Exec Prod    | " + format_name_list.call(item.video_details.program.exec_producers)
    puts "Producers    | " + format_name_list.call(item.video_details.program.producers)
    puts "Writers      | " + format_name_list.call(item.video_details.program.writers)
    # TODO: differentiate between program genre and series genre
    puts "Prog Genre   | " + item.video_details.program.genres.join(', ')
    puts "Series Genre | " + item.video_details.program.series.genres.join(', ')

    #puts "Choreogaphy  | " + format_name_list.call(item.video_details.program.choreographers)
    puts "Advisory     | " + item.video_details.program.advisory.join(', ')
    puts "Color Code   | " + item.video_details.program.color_code
    puts "Country      | " + item.video_details.program.country if item.video_details.program.country
  end
end

# search for regular expression in title, episode title, and description
def search
  options = OpenStruct.new
  OptionParser.new do |opts|
    opts.banner = <<-EOF
usage: #$progname search [options] patterns...

    Also reads patterns from stdin, one pattern per line.

EOF
  
    opts.on("-v", "--[no-]verbose", "Run verbosely") do |v|
      options.verbose = v
    end
  end.parse!

  items = TiVo::Container.now_playing.items
  SUPER_ARGV.each do |pattern|
    puts "-- #{pattern} --" if options.verbose
    reg = Regexp.new(pattern, Regexp::IGNORECASE)
    results = items.select do |item|
      reg === item.title \
        or reg === item.episode_title \
        or reg === item.description
    end
    if options.verbose
      results.each do |item|
        if item.episode_title
          puts "#{item.program_id} | #{item.title} - #{item.episode_title}"
        else
          puts "#{item.program_id} | #{item.title}"
        end
      end
    else
      results.each do |item|
        puts item.program_id
      end
    end
  end
end

##############################################################################

class CommandInterpreter
  attr_accessor :default_command, :version_string

  def initialize (&block)
    @default_command = 'help'
    @version_string = '(unknown)'
    @block = block
    @entries = Array.new

    help_string = <<-HELP
usage: help [SUBCOMMAND...]

Valid options:
    --version                : print client version info

  HELP
    on('help', :aliases=>['?', 'h'], :help=>help_string,
       :description=>"Describe the usage of this program or its subcommands.") do
      display_help 0 # will exit
    end

    block.call(self)
  end

  # possible arguments for args:
  #   - aliases     <- array of strings
  #   - description <- String
  #   - help        <- String or Proc
  #   - hidden      <- bool
  #
  # TODO: what should default help be?
  def on (name, args = Hash.new, &entry_point)
    entry = OpenStruct.new
    entry.name = name
    entry.entry_point = entry_point

    entry.aliases = (args[:aliases] || []) << name
    entry.description = args[:description]
    entry.help = args[:help] # || ''
    entry.hidden = args[:hidden]

    @entries << entry
  end

  def run
    @entries = @entries.sort_by { |entry| entry.name }

    command = ARGV.shift || @default_command

    if /-h|--help/ === command
      display_help 0 # will exit
    end
    if /-v|--version/ === command
      puts @version_string
      exit 0
    end

    entry = @entries.find do |entry|
      entry.aliases.include?(command)
    end
    if entry.nil?
      $stderr.puts "error: invalid command: " + command
      display_help 1
    end
    entry.entry_point.call
    self
  end

  protected

  # display_help exits the program when finished
  def display_help (exit_status)
    if ARGV.empty?
      display_general_help
    else
      display_command_help
    end

    exit exit_status
  end

  def display_general_help
    puts <<-HEADER
usage: #$progname <subcommand> [options] [args]
Type '#$progname help <subcommand>' for help on a specific subcommand.

HEADER
    puts "Available commands:"
    subcommands = @entries.collect do |entry|
      next if entry.hidden
      aliases = (entry.aliases - [entry.name])
      aliases = (entry.aliases - [entry.name])
      alias_string = aliases.empty? ? '' : " (#{aliases.join(', ')})"
      sub = OpenStruct.new
      sub.head = "   #{entry.name}#{alias_string}"
      sub.tail = entry.description
      sub
    end.compact
    max_len = subcommands.map { |sub| sub.head.length }.max
    max_len += GENERAL_HELP_PADDING
    subcommands.each do |sub|
      print sub.head
      print ' ' * (max_len - sub.head.length)
      puts sub.tail
    end
  end

  def display_command_help
    command = ARGV.first
    entry = @entries.find do |entry|
      entry.aliases.include?(command)
    end
    if entry.nil?
      $stderr.puts "error: invalid command: " + command
      exit 1
    end

    aliases = (entry.aliases - [entry.name])
    alias_string = aliases.empty? ? '' : " (#{aliases.join(', ')})"
    puts "#{entry.name}#{alias_string}: #{entry.description}"

    case entry.help
    when String
      puts entry.help
    when Proc
      entry.help.call
    else
      fail "i don't know how to handle this help type: #{entry.help.class}"
    end
    if entry.nil?
      $stderr.puts "error: invalid command: " + command
      exit 1
    end
  end
end

list_help_msg = <<-EOF
usage: #$progname ls

    Note:  Folders are not used since operations are processed recursively.
EOF

CommandInterpreter.new do |ci|
  ci.default_command = 'list'
  ci.version_string = "#$progname, version #{PROG_VERSION}"
  ci.on('list', :aliases=>['ls'], :help=>list_help_msg,
        :description=>"List all programs.",
        &method(:list).to_proc)
  ci.on('get', :help=>proc{ARGV.unshift("--help"); get},
        :description=>"Download programs by id.",
        &method(:get).to_proc)
  ci.on('details', :help=>proc{ARGV.unshift("--help"); details},
        :description=>"Get program details by id.",
        &method(:details).to_proc)
  ci.on('search', :help=>proc{ARGV.unshift("--help"); search},
        :description \
        => "Search for regexp in title, episode title, and description.",
        &method(:search).to_proc)
  ci.on('egg', :aliases=>['easteregg', 'easter_egg', 'easter-egg'],
        :hidden=>true, :help=>"wouldn't you like to know") do
    open('|fortune -c') do |io|
      src = io.readline
      io.readline
      puts "#{io.readlines}\n#{src}"
    end
  end
end.run
