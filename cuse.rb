require 'byebug'
require 'date'
require 'digest'
require 'json'
require 'net/http'
require 'socket'  
require 'tk'
require 'zlib'

# NOTES (for vid/tut):
# - Levels are cached, so switch tab / search / wait
# - If program exits badly, reopen and reclose to repatch library

################################################################################
#                      CONSTANTS AND GLOBAL VARIABLES                          #
################################################################################

# DO NOT modify the value of anything marked with a #! comment, their value
# depends on N++ or outte, so the program won't work if changed.

# < ------------------------- Backend constants ------------------------------ >

# General behaviour constants
TEST       = true  # Use test outte (at localhost)
INTERCEPT  = true  # Whether to intercept or forward userlevel requests
ALL_TABS   = false # Intercept from all tabs (as opposed to only Search)
PAGING     = false # Whether to allow scrolling in-game to change the page
LOG_CLI    = false # Log to terminal as well

# Debug constants
EXPORT     = false # Export raw HTTP requests and responses
EXPORT_DBG = false # Export entire HTTP process debug info
EXPORT_REQ = false # Export only requests
EXPORT_RES = false # Export only responses

# Network constants
TARGET        = "https://dojo.nplusplus.ninja" #! Metanet server address
OUTTE         = TEST ? "127.0.0.1" : "45.32.150.168" #! outte server address
PORT_OUTTE    = 8125 #! Default port used to comunicate with outte
TIMEOUT_NPP   = 0.25 # Time to wait for the game (local, so quick)
TIMEOUT_OUTTE = 5    # Time to wait for outte (not local, so long)

CACHE_SIZE    = 1024        # Number of cache slots
CACHE_TIMEOUT = 2 * 60 * 60 # Cache expire duration

CONFIG_FILENAME = "cuse.ini"
BACKGROUND_LOOP = 5 # Check background tasks every 5 mins

# < ------------------------- Backend variables ------------------------------ >

$port_npp  = 8124 # Default port used to comunicate with the game
$proxy     = "127.0.0.1:#{$port_npp}".ljust(TARGET.length, "\x00") #!
$last_req  = ""   # Last request string input by user
$socket    = nil  # Permanent socket with the game
$res       = nil  # Store outte's response, to forward to the game
$count     = 1    # Proxied request counter
$root_page = 0    # Page that'll show at the top in-game
$page      = 0    # Current page (different if we've scrolled down)

# < ------------------------- Frontend constants ----------------------------- >

# Interface constants
DEFAULT_SEARCH   = "Unnamed search"     # Default value of search profiles
INITIAL_DATE     = Date.new(2015, 6, 2) # Date of first userlevel
DATE_FORMAT      = "%d/%m/%Y"           #! Format for date filter in searches
TIME_FORMAT_NPP  = "%Y-%m-%d-%H:%M"     #! Datetime format used by N++
TIME_FORMAT_CUSE = "%d/%m/%Y %H:%M"     # Datetime format used by CUSE
TIME_FORMAT_LOG  = "%H:%M:%S.%L"        # Time format for the log box

# Colors
COLOR_LOG_NORMAL  = "#000"
COLOR_LOG_WARNING = "#F70"
COLOR_LOG_ERROR   = "#F00"
COLOR_TREE        = "#FDD"
COLOR_LABEL       = "#DDF"

# < ------------------------- Frontend variables ----------------------------- >

$config  = {}
$filters = {}
$flags     = {
  res: {
    empty:          false,
    invalid_format: false,
    invalid_length: false,
    invalid_type:   false,
    invalid_mode:   false
  }
}


################################################################################
#                                    UTILS                                     #
################################################################################

def log_exception(msg, e)
  Log.err(msg) unless msg.empty?
  Log.debug(e)
  Log.trace(e.backtrace.join("\n"))
end

def time(t)
  "%.3fms" % (1000 * (Time.now - t))
end

def _pack(n, size)
  n.to_s(16).rjust(2 * size, "0").scan(/../).reverse.map{ |b|
    [b].pack('H*')[0]
  }.join.force_encoding("ascii-8bit")
end

def _unpack(bytes, fmt = nil)
  if bytes.is_a?(Array) then bytes = bytes.join end
  if !bytes.is_a?(String) then bytes.to_s end
  i = bytes.unpack(fmt)[0] if !fmt.nil?
  i ||= bytes.unpack('H*')[0].scan(/../).reverse.join.to_i(16)
rescue
  if bytes.is_a?(Array) then bytes = bytes.join end
  bytes.unpack('H*')[0].scan(/../).reverse.join.to_i(16)
end

def to_utf8(str)
  str.bytes.reject{ |b| b < 32 || b == 127 }.map(&:chr).join.scrub('_')
end

def parse_str(str)
  to_utf8(str.split("\x00")[0].to_s).strip
end

def parse_date(str)
  Date.strptime(str, DATE_FORMAT) rescue nil
end

def format_date(date)
  date.strftime(DATE_FORMAT)
end

def parse_time(str)
  DateTime.strptime(str, TIME_FORMAT_NPP) rescue nil
end

def format_time(time)
  time.strftime(TIME_FORMAT_CUSE)
end

def escape(str)
  str.dump[1..-2]
end

def unescape(str)
  "\"#{str}\"".undump
end

def bench(action)
  @t ||= Time.now
  @total ||= 0
  @step ||= 0
  case action
  when :start
    @step = 0
    @total = 0
    @t = Time.now
  when :step
    @step += 1
    int = Time.now - @t
    @total += int
    @t = Time.now
    puts ("Benchmark #{@step}: #{"%.3fms" % (int * 1000)} (Total: #{"%.3fms" % (@total * 1000)}).")
  end
end

################################################################################
#                                   BACKEND                                    #
################################################################################

def background_tasks
  while true
    sleep(BACKGROUND_LOOP)
    Cache.expire
  end
rescue
  sleep(5)
  retry
end

# < -------------------------- File management ------------------------------- >

def find_lib
  paths = {
    'windows' => "",
    'linux'   => "#{Dir.home}/.steam/steam/steamapps/common/N++/lib64/libnpp.so"
  }
  sys = 'linux'
  paths[sys]
end

def patch
  path = find_lib
  Log.debug("Patching #{path}...")
  IO.binwrite(find_lib, IO.binread(find_lib).gsub(TARGET, $proxy))
  Log.info('Patched files')
end

def depatch
  path = find_lib
  Log.debug("Depatching #{path}...")
  IO.binwrite(find_lib, IO.binread(find_lib).gsub($proxy, TARGET))
  Log.info('Depatched files')
end

# < ---------------------------- Socket management --------------------------- >

def read(client, npp)
  req = ""
  begin
    if !npp
      req << client.read
    else
      req << client.read_nonblock(16 * 1024) while true
    end
  rescue Errno::EAGAIN
    if IO.select([client], nil, nil, npp ? TIMEOUT_NPP : TIMEOUT_OUTTE)
      retry
    else
      return nil if req.size == 0
    end
  rescue
  end
  req
end

def clear_headers(http)
  http.delete('accept-encoding')
  http.delete('accept')
  http.delete('user-agent')
  http.delete('host')
  http.delete('content-length')
  http.delete('content-type')
  http
end

def intercept(req)
  return forward(req) if !INTERCEPT
  pars = parse_params(req.split("\n")[0].split[1])
  if PAGING
    $page = $root_page + pars['page'].to_i
    server_call
  end
  body = validate_res($res, pars)
  status = "HTTP/1.1 200 OK\r\n"
  headers = {
    'content-type'   => 'application/octet-stream',
    'content-length' => body.size.to_s,
    'connection'     => 'keep-alive'
  }.map{ |k, v| "#{k}: #{v}\r\n" }.join
  "#{status}#{headers}\r\n#{body}"
end

def forward(req)
  # Build proxied request
  method, path, protocol = req.split("\r\n")[0].split
  path = path.sub(/\/[^\/]+/, '') unless path[1..4] == 'prod'
  uri = URI.parse(TARGET + path)
  case method.upcase
  when 'GET'
    reqNew = Net::HTTP::Get.new(uri)
  when 'POST'
    reqNew = Net::HTTP::Post.new(uri)
  else
    raise "Unknown HTTP method requested by N++"
  end
  reqNew = clear_headers(reqNew)
  req.split("\r\n\r\n")[0].split("\r\n")[1..-1].map{ |h| h.split(':') }.each{ |h|
    reqNew[h[0]] = h[1].strip
  }
  reqNew['host'] = TARGET[8..-1]
  reqNew.body = req.split("\r\n\r\n")[1..-1].join("\r\n\r\n")
  # Execute proxied request
  res = ""
  f = File.open("dbg_#{$count}", "wb") if EXPORT || EXPORT_DBG
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = true
  http.read_timeout = 2
  http.set_debug_output(f) if EXPORT || EXPORT_DBG
  res = http.start{ |http| http.request(reqNew) }
  f.close if EXPORT || EXPORT_DBG
  # Build proxied response
  status = "HTTP/1.1 #{res.code} #{res.msg}\r\n"
  headers = res.to_hash.map{ |k, v| "#{k}: #{v[0]}\r\n" }.join
  "#{status}#{headers}\r\n#{res.body}"
end

# < ----------------------------- N++-related -------------------------------- >

def empty_query(pars)
  cat     = pars.key?('search') ? 36 : (pars['qt'].to_i || 10)
  mode    = pars['mode'].to_i || 0
  header  = Time.now.strftime("%Y-%m-%d-%H:%M") # Date of query  (16B)
  header += _pack(0,    4)                      # Map count      ( 4B)
  header += _pack(0,    4)                      # Query page     ( 4B)
  header += _pack(0,    4)                      # Type           ( 4B)
  header += _pack(cat,  4)                      # Query category ( 4B)
  header += _pack(mode, 4)                      # Game mode      ( 4B)
  header += _pack(5,    4)                      # Cache duration ( 4B)
  header += _pack(500,  4)                      # Max page size  ( 4B)
  header += _pack(0,    4)                      # ?              ( 4B)
  header
end

def parse_params(path)
  path.split('?').last.split('&').map{ |p| p.split('=') }.to_h
end

# TODO: Add more integrity checks (map count, block lengths, etc)
def validate_res(res, pars)
  # Response needs to be initialized
  if res.nil?
    $flags[:res][:empty] = true
    log_flags(:res)
    return empty_query(pars)
  end

  # Response needs to be a string
  if !res.is_a?(String)
    $flags[:res][:invalid_format] = true
    log_flags(:res)
    return empty_query(pars)
  end

  # Response needs to be at least 48 bytes, the size of an empty query
  if res.size < 48
    $flags[:res][:invalid_length] = true
    log_flags(:res)
    return empty_query(pars)
  end

  # Type needs to be 0 (level)
  $flags[:res][:invalid_type] = true if _unpack(res[24...28]) != 0

  # Mode (solo, coop, race) needs to match the game's
  $flags[:res][:invalid_mode] = true if _unpack(res[32...36]) != pars['mode'].to_i

  if $flags[:res].values.count(true) > 0
    log_flags(:res)
    return empty_query(pars)
  end 

  # Set QT and page manually and return response
  cat = pars.key?('search') ? 36 : (pars['qt'] || 10).to_i
  page = (pars['page'] || 0).to_i
  res[20...24] = _pack(page, 4)
  res[28...32] = _pack(cat,  4)
  res
end

# < ----------------------- Main program flow control ------------------------ >

def server_startup
  $socket = TCPServer.new($port_npp)
  patch
  Log.info('Server started')
  Log.debug("Listening at port #{$port_npp}")
rescue Errno::EADDRINUSE
  $port_npp += 1
  $port_npp += 1 if $port_npp == PORT_OUTTE
  retry
rescue => e
  log_exception("Couldn't start server, try restarting", e)
end

def server_loop
  client = $socket.accept
  req = client.gets
  method, path, protocol = req.split
  Log.debug("Received #{method} to #{path.split('?')[0].split('/')[-1]}")
  req << read(client, true).to_s
  IO.binwrite("req_#{$count}", req) if EXPORT || EXPORT_REQ
  query = path.split('?')[0].split('/')[-1]
  t = Time.now
  if method == 'GET' && (query == 'levels' || ALL_TABS && query == 'query_levels')
    Log.debug("Intercepting #{method}...")
    res = intercept(req)
    Log.debug("Intercepted with #{res.size} bytes (#{time(t)})")
  else
    Log.debug("Forwarding #{method} to Metanet...")
    res = forward(req)
    Log.debug("Received #{res.size} bytes from Metanet (#{time(t)})")
  end
  IO.binwrite("res_#{$count}", res) if EXPORT || EXPORT_RES
  client.write(res)
  client.close
  Log.debug("Sent #{res.size} bytes to N++")
  $count += 1
rescue => e
  log_exception('Unknown server error', e)
  client.close if client.is_a?(BasicSocket)
end

def server_shutdown
  depatch
  Log.info('Server stopped')
end

def server_call(req = $last_req)
  Socket.tcp(OUTTE, PORT_OUTTE) do |conn|
    t = Time.now
    msg = "page #{$page + 1} #{req}"
    Log.debug("Requesting outte \"#{msg}\"...")
    conn.write(msg)
    conn.close_write
    Log.debug("Waiting for outte...")
    res = read(conn, false)
    $last_req = req
    conn.close
    if res.nil?
      Log.err('Connection to outte timed out')
    else
      Log.debug("Received #{res.size} bytes from outte (#{time(t)})")
      $res = res.dup
    end
    return res
  end
rescue => e
  log_exception('Unable to connect to outte', e)
end

################################################################################
#                                   FRONTEND                                   #
################################################################################

# < ----------------------- File and flag management ------------------------- >

def default_config
  {
    'searches' => [
      {
        'name' => 'Empty',
        'filters' => {
          'Title'      => '',
          'Author'     => '',
          'Author ID'  => '',
          'Mode'       => 'Solo',
          'Tab'        => 'Best',
          'After'      => '',
          'Before'     => '',
          'Min ID'     => '',
          'Max ID'     => '',
          '0th by'     => '',
          '0th not by' => '',
          'Scores'     => ''
        },
        'states' => {
          'Title'      => false,
          'Author'     => false,
          'Author ID'  => false,
          'Mode'       => false,
          'Tab'        => false,
          'After'      => false,
          'Before'     => false,
          'Min ID'     => false,
          'Max ID'     => false,
          '0th by'     => false,
          '0th not by' => false,
          'Scores'     => false
        }
      },
      {
        'name' => 'Sample search',
        'filters' => {
          'Title'      => 'Untitled',
          'Author'     => 'Melancholy',
          'Author ID'  => '117031',
          'Mode'       => 'Solo',
          'Tab'        => 'Featured',
          'After'      => format_date(INITIAL_DATE),
          'Before'     => format_date(Time.now),
          'Min ID'     => '22715',
          'Max ID'     => '110000',
          '0th by'     => 'Slomac',
          '0th not by' => 'Slomac',
          'Scores'     => '20'
        },
        'states' => {
          'Title'      => true,
          'Author'     => false,
          'Author ID'  => false,
          'Mode'       => false,
          'Tab'        => false,
          'After'      => false,
          'Before'     => false,
          'Min ID'     => false,
          'Max ID'     => false,
          '0th by'     => false,
          '0th not by' => false,
          'Scores'     => false
        }
      }
    ]
  }
end

def load_config
  if File.file?(CONFIG_FILENAME)
    $config = JSON.parse(File.read(CONFIG_FILENAME))
    Log.info("Loaded config file")
  else
    $config = default_config
    Log.info("No config file found, loaded defaults")
  end
rescue
  $config = default_config
  Log.warn("Error loading config file, loaded defaults")
end

def save_config
  File.write(CONFIG_FILENAME, JSON.pretty_generate($config))
  Log.debug("Saved config file")
rescue
  Log.warn("Failed to save config file")
end

def log_flags(type)
  return if !$flags.key?(type)
  msg = $flags[type].map{ |f, v|
    if !v
      nil
    else
      case f
      when :empty
        'no search has been made yet'
      when :invalid_format
        'bad format'
      when :invalid_length
        'bad length'
      when :invalid_type
        'bad type'
      when :invalid_mode
        'bad mode'
      end
    end
  }.compact.map(&:to_s)
  Log.debug("Invalid response: #{msg.join(', ')}") if msg.size > 0
end

# < -------------------------------- Classes --------------------------------- >
#
# Generic widgets:
#   1. Tooltip:    Custom info frame when hovering over widgets
#   2. Button:     Button with an icon and a tooltip
#   3. Scrollable: Generic container to add scrollbars to children widgets
#   4. Pager:      Widget with 4 buttons and a label, for page navigation
# Specific widgets:
#   5. Search:      Search profiles, holding all search terms and filters
#   6. Filter:      A single filter, including the checkbox, text entry, etc
#   7. LevelSet:    Search result, holding userlevels, and drawing the table
#   8. Cache:       Stores search results, and manages expiration, etc
#   9. Tab:         Keeps track of the search history and drawing each tab
#  10. Log:         Logging class, responsible for drawing the logbox

class Tooltip
  def initialize(widget, text = " ? ")
    @wraplength = 180
    @widget     = widget
    @text       = text   
    @label      = nil
    @widget.bind('Enter'){ enter }
    @widget.bind('Leave'){ leave }
  end

  def enter
    x = @widget.winfo_pointerx - $root.winfo_rootx + 10
    y = @widget.winfo_pointery - $root.winfo_rooty + 10
    @label = TkLabel.new(
      $root,
      text:        @text,
      justify:     'left',
      background:  "#ffffff",
      relief:      'solid',
      borderwidth: 1,
      wraplength:  @wraplength
    )
    @label.place(in: @widget, x: 0, y: @widget.winfo_height)
  end

  def leave  
    @label.place_forget
    @label = nil
  rescue
  end
end # End Tooltip

class Button < TkButton
  def initialize(frame, image, row, column, tooltip, command, padx = 0, pady = 0)
    super(frame, image: TkPhotoImage.new(file: image), command: command)
    self.grid(row: row, column: column, sticky: 'nsew', padx: padx, pady: pady)
    if !tooltip.nil? && !tooltip.empty? then Tooltip.new(self, tooltip) end
  end
end # End Button

class Scrollable
  attr_reader :widget

  def initialize(frame, row, col, &block)
    @frame = TkFrame.new(frame).grid(row: row, column: col, sticky: 'news')
    @frame.grid_columnconfigure(0, weight: 1)
    @scroll = TkScrollbar.new(@frame, orient: 'vertical')
    @widget = (yield @frame).grid(row: 0, column: 0, sticky: 'news')
    @scroll.command = -> (*args) { @widget.yview(*args) }
    @widget.yscrollcommand = -> (*args) { @scroll.set(*args) }
    update
  end

  def update
    lines <= @widget.height ? @scroll.ungrid : @scroll.grid(row: 0, column: 1, sticky: 'ns')
  end

  def lines
    case @widget.class.to_s
    when "Tk::Listbox"
      @widget.size
    when "Tk::Text"
      @widget.index('end').split('.')[0].to_i - 2
    else
      0
    end
  end
end # End Scrollable

class Pager

  def initialize(frame, name, type, page, pages, callback_first, callback_prev, callback_next, callback_last)
    type = 'a' if !['a', 'b'].include?(type)
    @name = name
    @type = type
    @page = page.clamp(0, pages)
    @pages = pages
    @frame = TkFrame.new(frame)
    Button.new(@frame, "icons/first_#{type}.gif", 0, 0, "First #{name.downcase}", callback_first)
    Button.new(@frame, "icons/prev_#{type}.gif", 0, 1, "Previous #{name.downcase}", callback_prev)
    @label = TkLabel.new(@frame).grid(row: 0, column: 2)
    Button.new(@frame, "icons/next_#{type}.gif", 0, 3, "Next #{name.downcase}", callback_next)
    Button.new(@frame, "icons/last_#{type}.gif", 0, 4, "Last #{name.downcase}", callback_last)
    update
  end

  def update(page = @page, pages = @pages)
    @page = page.clamp(0, pages)
    @pages = pages
    @label.text = "#{@name} #{@page} / #{@pages}"
  end

  def grid(row, col, sticky)
    @frame.grid(row: row, column: col, sticky: sticky)
    self
  end

end # End Pager

class Search
  attr_accessor :name, :filters, :states, :hidden
  @@searches = {}  # Hash of search profiles
  @@entry    = nil # TkEntry
  @@list     = nil # TkListbox
  @@scroll   = nil # TkScrollbar
  @@frame    = nil # TkFrame to hold the widgets
  @@length   = 6   # Onscreen list length

  # Default and saved searches
  def self.init
    @@searches['Sample search'] = Search.new(
      'Sample search',
      $config['searches'].find{ |s| s['name'] == 'Sample search' }['filters'].dup,
      $config['searches'].find{ |s| s['name'] == 'Sample search' }['states'].dup,
      false, 
      false
    )
    @@searches['Empty'] = Search.new(
      'Empty',
      $config['searches'].find{ |s| s['name'] == 'Empty' }['filters'].dup,
      $config['searches'].find{ |s| s['name'] == 'Empty' }['states'].dup,
      true,
      false
    )
    populate
  end

  # TODO: Use Scrollable
  def self.draw(frame, row, col)
    @@frame = TkFrame.new(frame).grid(row: row, column: col, sticky: 'new')
    @@frame.grid_columnconfigure(0, weight: 1)
    @@entry = TkEntry.new(@@frame).grid(row: 0, column: 0, columnspan: 2, sticky: 'ew')
    @@scroll = TkScrollbar.new(@@frame, orient: 'vertical')
    @@list  = TkListbox.new(@@frame, selectmode: 'browse', width: 10, height: @@length).grid(row: 1, column: 0, sticky: 'ew')
    @@list.bind('<ListboxSelect>', ->{ update_entry; load })
    @@list.yscrollcommand = -> (*args) { @@scroll.set(*args) }
    @@scroll.command = -> (*args) { @@list.yview(*args) }
    update_list
  end

  # Parse config file for saved searches
  def self.populate
    $config['searches'].each{ |search|
      next if ['Sample search', 'Empty'].include?(search['name'])
      @@searches[search['name']] = Search.new(search['name'], search['filters'].dup, search['states'].dup)
    }
  rescue
    Log.warn("Couldn't load saved searches, loaded defaults")
  end

  def self.find(name)
    @@searches[name]
  end

  # Correct name by adding index in case of repetitions
  def self.find_name(name)
    name = DEFAULT_SEARCH if name.strip.empty?
    name = name.gsub(/\(\d+\)$/, '').strip
    matches = @@searches.keys.select{ |n| n == name || n =~ /^#{name} \(\d+\)$/ } 
    return name if matches.empty?
    index = [(matches.map{ |n| n[/\((\d+)\)$/, 1].to_i }.max || 1) + 1, 2].max
    return "#{name} (#{index})"
  end

  def self._load(name)
    return if !@@searches.key?(name)
    Filter.update(@@searches[name].filters, @@searches[name].states)
    Filter.validate
  end

  def self.load
    selection = @@list.curselection[0]
    return if selection.nil?
    name = @@list.get(selection)
    return if name.nil?
    _load(name)
  rescue => e
    log_exception("Failed to load search", e)
  end

  def self.save
    name = find_name(@@entry.value)
    Filter.validate
    f = Filter.filters
    s = Filter.states
    @@searches[name] = Search.new(name, f, s)
    update_list
    $config['searches'] << {
      'name' => name,
      'filters' => f,
      'states' => s
    }
    save_config
  rescue => e
    log_exception("Failed to save search", e)
  end

  def self.delete
    selection = @@list.curselection[0]
    return if selection.nil?
    name = @@list.get(selection)
    return if !@@searches.key?(name)
    @@searches[name].delete
  end

  def self.clear
    _load('Empty')
  end

  def self.update_list
    @@list.value = @@searches.values.select{ |s| !s.hidden }.map(&:name)
    @@list.size <= @@length ? @@scroll.ungrid : @@scroll.grid(row: 1, column: 1, sticky: 'ns')
  end

  def self.update_entry
    selection = @@list.curselection[0]
    return if selection.nil?
    name = @@list.get(selection)
    return if !@@searches.key?(name)
    @@entry.value = name
  end

  # The 'key' is a string that uniquely identifies the search, for properly
  # caching the results
  def self.execute
    Filter.validate
    filters = Filter.list.select{ |name, filter| filter.state }.map{ |name, filter|
      [name, filter.value.downcase]
    }
    key = filters.to_json
    slot = Cache.get(key)
    if slot.nil?
      srch = filters.map{ |name, filter|
        "#{name.downcase} \"#{escape(filter)}\""
      }.join(' ')
      res = server_call(srch)
      level_set = !res.nil? ? LevelSet.new(key, res) : nil
    else
      Log.debug("Found cached block of #{slot.size} levels.")
      level_set = slot
    end
    Tab.add(level_set)
  rescue => e
    Log.err("Failed to execute search", e)
  end

  def initialize(name, filters, states, hidden = false, deletable = true)
    @name      = name
    @filters   = filters
    @states    = states
    @hidden    = hidden
    @deletable = deletable
    @@searches[@name] = self
  end

  def delete
    return if !@deletable
    return if confirm('Delete search', 'Are you sure?') == 'no'
    @@searches.delete(@name)
    self.class.update_list
    $config['searches'].delete_if{ |s| s['name'] == @name }
    save_config
  rescue => e
    log_exception("Failed to delete search", e)
  end
end # End Search

class Filter
  @@filters = {}   
  @@incompat = [ ['Author', 'Author ID'] ] # Lists of incompatible filters
  @@warnings = []

  def self.update(filters, states)
    filters.each{ |name, value|
      next if !@@filters.key?(name) || !states.key?(name)
      @@filters[name].update(states[name], value)
    }
  end

  # TODO: Add check (and warning) for 0th owner == 0th not owner
  def self.validate(warn = false)
    # Validate all filters individually
    @@filters.each{ |name, f| f.validate(true) }

    # Make sure there are no incompatible filters enabled
    @@incompat.each{ |list|
      list.select{ |name|
        @@filters.key?(name) && @@filters[name].state == true
      }[1..-1].to_a.each{ |name|
        @@filters[name].update_state(false)
      }
    }

    # Date check
    date1 = parse_date(@@filters['After'].value)
    date2 = parse_date(@@filters['Before'].value)
    if !date1.nil? && !date2.nil? && date1 > date2
      @@filters['After'].update_text(format_date(date2))
      @@filters['Before'].update_text(format_date(date1))
      @@warnings.push("'After' date was greater than 'Before' date -> Swapped") if warn
    end

    # Map ID check
    id1 = @@filters['Min ID'].value
    id2 = @@filters['Max ID'].value
    if id1.to_i > id2.to_i
      @@filters['Min ID'].update_text(id2)
      @@filters['Max ID'].update_text(id1)
      @@warnings.push("'Min ID' was greater than 'Max ID' -> Swapped") if warn
    end

    if warn
      Log.warn("Some filters were fixed:\n#{@@warnings.join("\n")}")
      @@warnings = []
    end
  end

  def self.list
    @@filters
  end

  def self.filters
    @@filters.map{ |name, f| [name, f.value] }.to_h
  end

  def self.states
    @@filters.map{ |name, f| [name, f.state] }.to_h
  end

  def initialize(parent, name, value, state)
    # Internal variables
    @name     = name
    @old_val  = value
    @klass    = nil
    @limit    = nil
    @type     = nil
    @readonly = false
    @entries  = []

    # Figure out value of variables based on widget name
    if ['Mode', 'Tab'].include?(name)
      @klass = 'combo'
      @limit = 10
      case name
      when 'Mode'
        @entries = ['Solo', 'Coop', 'Race']
      when 'Tab'
        @entries = ['Best', 'Featured', 'Top Weekly', 'Hardest']
      end
      @old_val = @entries.include?(value) ? value : @entries[0]
    elsif ['Scores'].include?(name)
      @readonly = true
      @klass = 'spin'
      @limit = 2
    else
      @klass = 'entry'
      if ['Author ID', 'Min ID', 'Max ID'].include?(name)
        @type = 'int'
        @limit = 7
      elsif ['Before', 'After'].include?(name)
        @type = 'date'
        @limit = 10
      else
        @type = 'string'
        @limit = name == 'Author' ? 16 : 127
      end
    end

    # Widget variables
    @vName  = TkVariable.new(name)
    @vText  = TkVariable.new(value)
    @vCheck = TkVariable.new(state)
    @vText.trace('w', proc { validate })

    # Widget objects
    case @klass
    when 'entry'
      @wText = TkEntry.new(parent, textvariable: @vText, bg: 'white')
    when 'combo'
      @wText = TkCombobox.new(parent, textvariable: @vText, values: @entries)
    when 'spin'
      @wText = TkSpinbox.new(
        parent,
        textvariable:       @vText,
        from:               0,
        to:                 20,
        state:              'readonly',
        repeatdelay:        100,
        repeatinterval:     25,
        readonlybackground: 'white')
    end
    Tooltip.new(@wText, 'DD/MM/YYYY') if @type == 'date'
    @wText.bind('FocusOut'){ validate(true) }
    @wName  = TkLabel.new(parent, textvariable: @vName)
    @wCheck = TkCheckButton.new(parent, variable: @vCheck, command: ->{ update_state })

    # Initialize widget values to default
    update(Search.find('Sample search').states[@name], Search.find('Sample search').filters[@name])
    @@filters[@name] = self
  end

  # Validate filter content based on class and type:
  #   Normal validation: More basic, executed on each modification.
  #   Final validation: More complex, executed when focus is changed.
  # TODO: Add warnings for some validation fails (e.g. wrong date formats)
  def validate(final = false)
    new_val = value[0...@limit]
    return update_state(false) if final && new_val.strip.empty?
    if @klass == 'combo'
      @entries.include?(new_val) ? @old_val = new_val : new_val = @old_val
    else
      case @type
      when 'int'
        new_val = new_val[/\d+/].to_s
      when 'date'
        new_val = new_val.gsub(/[^0-9\/]/, '')
        if final
          date1 = INITIAL_DATE
          date2 = Date.today
          date = parse_date(new_val)
          if !date.nil?
            date = date.clamp(date1, date2)
          else
            date = @name == 'After' ? date1 : date2
          end
          new_val = format_date(date)
        end
      end
    end
    new_val = new_val[0...@limit]
    update_text(new_val) unless new_val == value
  end

  def value
    @vText.string
  end

  def state
    @vCheck.bool
  end

  def update_state(state = nil)
    @vCheck.bool = state if [true, false].include?(state)
    @wText.state = @vCheck == false ? 'disabled' : (@readonly ? 'readonly' : 'normal')
    return if @vCheck == false
    @@incompat.each{ |list|
      next if !list.include?(@name)
      list.each{ |name|
        next if name == @name || !@@filters.key?(name)
        @@filters[name].update_state(false)
      }
    }
  end

  def update_text(text)
    @vText.string = text
  end

  def update(state, text)
    update_state(state)
    update_text(text)
  end

  def toggle(state = nil)
    @vCheck = state.nil? ? !@vCheck : !!state
  end

  # Recover TK geometry methods
  def grid(row, col)
    @wCheck.grid(row: row, column: col,     sticky: 'ew')
    @wName.grid(row: row,  column: col + 1, sticky: 'w')
    @wText.grid(row: row,  column: col + 2, sticky: 'ew')
  end
  #def pack(**args)  @wFrame.pack(args)  end
  #def place(**args) @wFrame.place(args) end
end # End Filter

class LevelSet
  attr_reader :levels, :key

  def initialize(key, raw)
    @key = key
    @header = {}
    @levels = []
    parse(raw)
    cache
  end

  def cache
    Cache.add(@key, self)
  end

  def size
    @levels.size
  end

  # TODO: Implement dumping the binary and sending to the game (probably by
  # setting a global var)
  def dump

  end

  # This will be called by the Cache when the block gets deleted
  def destroy
    @key = nil
    @header = nil
    @levels = nil
  end

  def parse(raw)
    # Parse header
    return if raw.size < 48
    Log.debug("Parsing header...")
    @header = {
      date:    parse_time(raw[0...16]),
      count:   _unpack(raw[16...20]),
      page:    _unpack(raw[20...24]),
      type:    _unpack(raw[24...28]),
      qt:      _unpack(raw[28...32]),
      mode:    _unpack(raw[32...36]),
      cache:   _unpack(raw[36...40]),
      max:     _unpack(raw[40...44]),
      unknown: _unpack(raw[44...48])
    }

    # Parse map headers
    Log.debug("Parsing map headers...")
    return if raw.size < 48 + 44 * @header[:count]
    @levels = raw[48 ... 48 + 44 * @header[:count]].chars.each_slice(44).map { |h|
      {
        'id'        => _unpack(h[0...4], 'l<'),
        'author_id' => _unpack(h[4...8], 'l<'),
        'author'    => parse_str(h[8...24].join),
        '++'        => _unpack(h[24...28], 'l<'),
        'date'      => format_time(parse_time(h[28..-1].join))
      }
    }

    # Parse map data
    Log.debug("Parsing map data...")
    i = 0
    offset = 48 + 44 * @header[:count]
    while i < @header[:count]
      break if raw.size < offset + 6
      len = _unpack(raw[offset...offset + 4])
      @levels[i]['count'] = _unpack(raw[offset + 4...offset + 6])
      break if raw.size < offset + len
      map = Zlib::Inflate.inflate(raw[offset + 6...offset + len])
      @levels[i]['title'] = parse_str(map[30...158])
      @levels[i]['tiles'] = map[176...1142].bytes.each_slice(42).to_a
      @levels[i]['objects'] = map[1222..-1].bytes.each_slice(5).to_a
      offset += len
      i += 1
    end

    Log.info("Downloaded #{@header[:count]} maps")
  rescue => e
    log_exception("Failed to parse userlevels", e)
  end
end # End LevelSet

class Cache
  @@slots = {} # Cache blocks
  @@index = 0  # Cache block counter

  # Set time of cache block to current
  def self.update_time(hash)
    slot = @@slots[hash]
    return false if slot.nil?
    slot[:time] = Time.now.to_i
    return true
  end

  # Retrieve a cached block
  def self.get(key)
    slot = @@slots.find{ |_, block| block[:key] == key }
    return nil if slot.nil?
    update_time(slot[0])
    return slot[1][:data]
  end

  # Free up n slots in the cache
  def self.free(n = 1)
    @@slots.min_by(n){ |_, block| block[:time] }.each{ |hash, block|
      delete(hash)
    }
  end

  # Delete expired slots
  def self.expire
    @@slots.select{ |_, block| Time.now.to_i - block[:time] >= CACHE_TIMEOUT }
           .each{ |hash, _| delete(hash) }
  end

  # Empty entire cache
  def self.clear
    @@slots.each{ |hash, _| delete(hash) }
    Log.debug("Cache cleared")
  end

  # Add a block of levels to the cache
  def self.add(key, obj)
    hash = hash(key)
    block = @@slots[hash]
    # If block is in cache, update date and return false
    if !block.nil?
      update_time(hash)
      return false
    end
    # If block is not in cache, create it (making sure there's space) and return true
    free(@@slots.size - CACHE_SIZE + 1) if @@slots.size >= CACHE_SIZE
    @@slots[hash] = {
      index: @@index,
      key:   key,
      data:  obj,
      time:  Time.now.to_i
    }
    Log.trace("Added block #{@@index} to cache.")
    @@index += 1
    return true
  end

  # Delete a cache block, invoking also the corresponding destructor
  def self.delete(hash)
    block = @@slots[hash]
    return false if block.nil?
    block[:data].destroy
    Log.trace("Deleted block #{block[:index]} from cache.")
    @@slots[hash] = nil
    @@slots.delete(hash)
    return true
  end

  # Compute hash of a string to use as key for the associative array
  def self.hash(key)
    Digest::MD5.digest(key)
  end
end # End Cache

# TODO: What happens when LevelSets expire? Make sure that when navigating
# tabs, and searches within tabs, we account for expired searches, such that
# if one is expired, we just reexecute it again, and perhaps store it where
# it originally was, without creating a new search slot at the end of the
# tab's history.
class Tab
  attr_reader :index

  @@tabs      = {}  # Array of tabs
  @@index     = 0   # Tab counter
  @frame      = nil # Frame to contain widgets
  @@tree      = nil # Tk::Tile::Treeview containing levels
  @@active    = nil # Currently active tab
  @@charwidth = 8   # Average font char size of elements
  @@minwidth  = 12  # Average font char size of headers
  @@fields    = {
    'id'     => { anchor: 'e', width: 7  },
    'title'  => { anchor: 'w', width: 24 },
    'author' => { anchor: 'w', width: 16 },
    'date'   => { anchor: 'w', width: 16 },
    '++'     => { anchor: 'e', width: 3  }
  }
  @@special_tabs = {
    open:  '+',  # Text of tab to open another tab
    close: 'x'   # Text of tab to close the active tab
  }

  def self.init(frame, row, col)
    @@frame = TkFrame.new(frame).grid(row: row, column: col, sticky: 'news')
    @@frame.grid_columnconfigure(0, weight: 1)
    @@notebook = Tk::Tile::Notebook.new(@@frame).grid(row: 0, column: 0, sticky: 'ew')
    # TODO: Add tooltips to the special tabs
    @@notebook.add(TkFrame.new, text: @@special_tabs[:open])
    @@notebook.add(TkFrame.new, text: @@special_tabs[:close])
    @@notebook.bind("<NotebookTabChanged>"){ update }
    @@frame2 = TkFrame.new(@@frame).grid(row: 1, column: 0, sticky: 'ew')
    @@frame2.grid_columnconfigure(0, weight: 1)
    @@pager_search = Pager.new(
      @@frame2,
      'Search',
      'b',
      0,
      0,
      -> { Tab.first_search },
      -> { Tab.prev_search },
      -> { Tab.next_search },
      -> { Tab.last_search }
    ).grid(0, 0, 'w')
    @@pager_pages = Pager.new(
      @@frame2,
      'Page',
      'a',
      0,
      0,
      -> {},
      -> {},
      -> {},
      -> {}
    ).grid(0, 1, 'e')
    @@tree = TkTreeview.new(
      @@frame,
      selectmode: 'browse',
      height:     25,
      columns:    @@fields.keys.join(' '),
      show:       'headings'
    ).grid(row: 2, column: 0, sticky: 'news')
    @@fields.each{ |name, attr|
      @@tree.column_configure(name, anchor: attr[:anchor], minwidth: name.length * @@minwidth, width: attr[:width] * @@charwidth)
      @@tree.heading_configure(name, text: name.capitalize)
    }
    @@label = TkText.new(@@frame, font: "TkDefaultFont 8", wrap: 'char', state: 'disabled', height: 1, background: COLOR_LABEL)
                    .grid(row: 3, column: 0, sticky: 'ew')
    @@label.tag_configure('bold', font: "TkDefaultFont 8 bold")
  end

  # Called whenever the active tab changes.
  # If a special tab (open/close) is clicked, we act accordingly.
  # If a normal tab is clicked, we update the userlevel table, and the
  #   variable holding the active tab.
  def self.update
    name = active_name
    return nil if name == ''
    case name
    when @@special_tabs[:open]
      open
    when @@special_tabs[:close]
      close
    else
      active.select
    end
  end

  # Update userlevel info table
  def self.update_tree
    @@tree.children('').each(&:delete)
    return if @@active.nil?
    level_set = @@active.level_set
    return if level_set.nil?
    level_set.levels.each{ |l|
      @@tree.insert('', 'end', values: @@fields.keys.map{ |f| l[f] })
    }
    $root.update # Update app display
  rescue => e
    log_exception("Failed to update userlevel list", e)
  end

  # Update search description text
  def self.update_label
    @@label.configure(state: 'normal')
    @@label.delete('1.0', 'end')
    @@label.configure(state: 'disabled')
    if @@active.nil? || @@active.level_set.nil?
      @@label.grid_remove rescue nil
      return
    end
    @@label.configure(state: 'normal')
    JSON.parse(@@active.level_set.key).map{ |name, value|
      @@label.insert('end', name, 'bold')
      @@label.insert('end', ": #{value}; ")
    }
    @@label.configure(state: 'disabled')
    @@label.grid
    $root.update # Update text widget so that display line count is accurate
    @@label.height = @@label.count('1.0', 'end', 'displaylines').clamp(1, 2)
  rescue => e
    log_exception("", e)
  end

  # Update labels of pagers
  def self.update_pagers
    if @@active.nil?
      @@pager_search.update(0, 0)
    else
      @@active.update_pagers
    end
  end

  # Update all widgets
  def self.update_widgets
    update_tree
    update_label
    update_pagers
  end

  def self.active_id
    @@notebook.index('current')
  rescue
    -1
  end

  def self.active_name
    id = active_id
    return '' if id == -1
    @@notebook.itemcget(id, :text)
  rescue
    ''
  end

  def self.active
    name = active_name
    return nil if name == '' || @@special_tabs.values.include?(name)
    @@tabs[name[/\d+/].to_i]
  rescue
    nil
  end

  # Add a new LevelSet to the current active tab
  def self.add(level_set)
    return if level_set.nil?
    tab = active
    tab = Tab.open if tab.nil?
    tab.add(level_set)
  rescue => e
    log_exception("Failed to add search to tab", e)
  end

  # Open a new tab and set as active
  def self.open
    @@index += 1
    name = "Tab #{@@index}"
    @@notebook.add(TkFrame.new, text: name)
    @@tabs[@@index] = Tab.new(@@index, name)
    Log.trace("Opened tab #{@@index}")
    @@tabs[@@index].select # Keep this line last, so that the tab is returned
  rescue => e
    Log.err("Failed to open tab", e)
  end

  # Close the current active tab
  def self.close
    return if @@active.nil?
    new_tab = @@active.next_tab(false) || @@active.prev_tab(false)
    @@active.destroy
    !new_tab.nil? ? new_tab.select : empty
  end

  def self.first_search
    return if @@active.nil?
    @@active.first_search
  end

  def self.prev_search
    return if @@active.nil?
    @@active.prev_search
  end

  def self.next_search
    return if @@active.nil?
    @@active.next_search
  end

  def self.last_search
    return if @@active.nil?
    @@active.last_search
  end

  def self.empty
    @@active = nil
    update_widgets
  end

  def initialize(index, name)
    @history = []    # Searches performed in this tab
    @pos     = -1    # Selected search from this tab
    @index   = index # Index of the tab (CUSE)
    @name    = name  # Label of the tab
  end

  # Find the Tk ID of the tab by its name
  def get_id
    @@notebook.index('end').times.each{ |i|
      return i if @@notebook.itemcget(i, :text) == @name
    }
    return -1
  rescue
    -1
  end

  def select
    id = get_id
    return nil if id == -1
    @@notebook.select(id)
    @@active = self
    self.class.update_widgets
    self
  rescue
    nil
  end

  def update_pagers
    @@pager_search.update(@pos + 1, @history.size)
  end

  # Navigate from one tab to another based on an ID offset
  # If we don't clamp, then nil is returned when the tab doesn't exist,
  # otherwise an actual tab should always be returned, even if it's the same one
  def nav_tab(offset = 0, clamp = true)
    id = get_id
    return nil if id == -1
    new_id = id + offset
    new_id = new_id.clamp(0, @@notebook.index('end') - 1) if clamp
    new_id = @@notebook.index(new_id) rescue -1
    return nil if new_id == -1
    @@tabs.find{ |_, tab| tab.get_id == new_id }[1]
  rescue
    nil
  end

  def next_tab(clamp = true)
    nav_tab(1, clamp)
  end

  def prev_tab(clamp = true)
    nav_tab(-1, clamp)
  end

  def select_search(index)
    return nil if @history.empty? || !index.between?(0, @history.size - 1)
    @pos = index
    self.class.update_widgets
  rescue
    nil
  end

  def nav_search(offset = 0)
    return if @history.empty?
    select_search((@pos + offset).clamp(0, @history.size - 1))
  end

  def first_search
    select_search(0)
  end

  def prev_search
    nav_search(-1)
  end

  def next_search
    nav_search(1)
  end

  def last_search
    select_search(@history.size - 1)
  end

  def add(level_set)
    return if level_set.nil? || @history.size > 0 && level_set.key == @history.last.key
    @history << level_set
    select_search(@history.size - 1)
  end

  # TODO: Implement delete method (for when searches expire, or somehow
  # keep them but reexecute them if needed (they're not cached anymore, so
  # this could be problematic, think about it).

  def level_set
    @history[@pos]
  end

  # Note that we do NOT destroy the underlying LevelSets, they remained cached for later
  def destroy
    @@tabs.delete(@index)
    @@notebook.forget(get_id)
    Log.trace("Closed tab #{@index}")
  rescue => e
    log_exception("Failed to close tab", e)
  end
end # End Tab

class Log
  @@log    = nil # TkText widget to store the info
  @@scroll = nil # TkScrollbar widget for the text widget
  @@frame  = nil # TkFrame to hold the widgets
  @@level  = nil # Logging level (1 most important, 4 least)

  def self.init(frame, row, col)
    @@frame = TkFrame.new(frame).grid(row: row, column: col, sticky: 'news')
    @@frame.grid_columnconfigure(0, weight: 1)
    @@log = Scrollable.new(@@frame, 0, 0) do |f|
      TkText.new(f, font: 'TkDefaultFont 8', foreground: COLOR_LOG_NORMAL, state: 'disabled', height: 8, wrap: 'char')
    end
    @@frame2 = TkFrame.new(@@frame).grid(row: 1, column: 0, sticky: 'ew')
    @@level = TkVariable.new(2)
    TkLabel.new(@@frame2, text: 'Logging level:').grid(row: 0, column: 0)
    @@b1 = TkRadiobutton.new(@@frame2, text: 'Minimal', variable: @@level, value: 1, command: -> { update_level })
                        .grid(row: 0, column: 1)
    @@t1 = Tooltip.new(@@b1, 'Only show errors and important info.')
    @@b2 = TkRadiobutton.new(@@frame2, text: 'Normal', variable: @@level, value: 2, command: -> { update_level })
                        .grid(row: 0, column: 2)
    @@t2 = Tooltip.new(@@b2, 'Show all normal info.')
    @@b3 = TkRadiobutton.new(@@frame2, text: 'Verbose', variable: @@level, value: 3, command: -> { update_level })
                        .grid(row: 0, column: 3)
    @@t3 = Tooltip.new(@@b3, 'Show normal info and debug info.')
    @@b4 = TkRadiobutton.new(@@frame2, text: 'All', variable: @@level, value: 4, command: -> { update_level })
                        .grid(row: 0, column: 4)
    @@t4 = Tooltip.new(@@b4, 'Show everything, including debug and error traces.')
    # Tags for text color
    @@log.widget.tag_configure('error', foreground: COLOR_LOG_ERROR)
    @@log.widget.tag_configure('warning', foreground: COLOR_LOG_WARNING)
    # Tags for log level (determines visibility)
    update_level
  end

  def self.log(type, text, tag = '')
    type += ': ' if type.is_a?(String) && !type.empty?
    msg = "[#{Time.now.strftime(TIME_FORMAT_LOG)}] #{type.to_s}#{text.to_s}\n"
    @@log.widget.configure(state: 'normal')
    @@log.widget.insert('end', msg, tag)
    @@log.widget.configure(state: 'disabled')
    scroll
    @@log.update
    print(msg) if LOG_CLI
  rescue
    # Necessary rescue to catch IOError when the program is not opened from
    # the console, causing STDOUT to not be open.
  end

  def self.scroll
    @@log.widget.see('end - 2l')
  end

  def self.update_level
    (1..4).each{ |l| @@log.widget.tag_configure(l.to_s, elide: @@level.to_i < l) }
    scroll
  end

  # Different log functions for different levels of severity
  def self.err(text)
    log('Error', text, 'error 1')
  end

  def self.broadcast(text)
    log('', text, '1')
  end

  def self.warn(text)
    log('Warning', text, 'warning 2')
  end

  def self.info(text)
    log('', text, '2')
  end

  def self.debug(text)
    log('', text, '3')
  end

  def self.trace(text)
    log('', text, '4')
  end
end # End Log

# < --------------------- General interface functions ------------------------ >

def init
  load_config
  Search.init
  Tk::Tile::Style.configure('Treeview', rowheight: 12, font: 'Courier 9', background: COLOR_TREE, fieldbackground: COLOR_TREE)
  Tk::Tile::Style.configure('Heading', font: 'TkDefaultFont 10')
end

def destroy
  save_config
  server_shutdown
  $root.destroy
end

def confirm(title, msg)
  Tk::messageBox(
    type:    'yesno', 
    title:   title,
    message: msg,
    icon:    'question', 
    default: 'no'
  )
end

def destroy_callback
  confirm('Quit', 'Really quit?') == 'yes' ? destroy : nil
end

# Switch focus to root if we click outside of a widget
# This is important because we use it to validate the fields automatically
# when clicking outside of them.
def defocus(event)
  focused = Tk.focus
  return nil if focused.nil? || focused == $root
  x1 = focused.winfo_rootx
  x2 = focused.winfo_rootx + focused.winfo_width
  y1 = focused.winfo_rooty
  y2 = focused.winfo_rooty + focused.winfo_height
  $root.focus if event.x_root < x1 || event.x_root > x2 || event.y_root < y1 || event.y_root > y2
end

# < ---------------------------- Build interface ----------------------------- >

# Root window
$root = TkRoot.new(title: "N++ Custom Userlevel Search Engine")
w, h = 720, 640
$root.minsize(w, h)
$root.geometry("#{w}x#{h}")
$root.grid_columnconfigure(1, weight: 1)
$root.resizable(true, false)
$root.bind('ButtonPress'){ |event| defocus(event) }
$root.protocol("WM_DELETE_WINDOW", -> { destroy_callback })

# Main frames
fSearch = TkFrame.new($root, width: 190, height: 640).grid(row: 0, column: 0, sticky: 'nws').grid_propagate(0)
fLevels = TkFrame.new($root).grid(row: 0, column: 1, sticky: 'news')
fSearch.grid_columnconfigure(0, weight: 1)
fLevels.grid_columnconfigure(0, weight: 1)

# Initialize config and others (don't move this line up)
init

# Filters
fFilters = TkFrame.new(fSearch).grid(row: 0, column: 0, sticky: 'new')
fFilters.grid_columnconfigure(2, weight: 1)
sample = Search.find('Sample search')
sample.filters.map{ |name, value|
  $filters[name] = Filter.new(fFilters, name, value, sample.states[name])
}
$filters.values.each_with_index{ |f, i| f.grid(i, 0) }

# Search
fButtons = TkFrame.new(fSearch).grid(row: 1, column: 0, sticky: 'w')
Button.new(fButtons, 'icons/new.gif',    0, 0, 'New',    ->{ Search.clear })
Button.new(fButtons, 'icons/save.gif',   0, 1, 'Save',   ->{ Search.save })
Button.new(fButtons, 'icons/delete.gif', 0, 2, 'Delete', ->{ Search.delete })
Button.new(fButtons, 'icons/search.gif', 0, 3, 'Search', ->{ Search.execute })
Button.new(fButtons, 'icons/npp.gif',    0, 4, 'Play',   ->{ })
Search.draw(fSearch, 2, 0)

TkCanvas.new(fSearch, width: 176, height: 100, background: 'white').grid(row: 3, column: 0)

# Level view
Tab.init(fLevels, 0, 0)

# Log
Log.init(fLevels, 1, 0)
Log.broadcast("Initialized")

################################################################################
#                                    START                                     #
################################################################################

trap 'INT' do destroy end
server_startup
threads = {}
threads[:server] = Thread.new{ server_loop while true }
threads[:background] = Thread.new{ background_tasks while true }
#threads[:input] = Thread.new{ server_call(STDIN.gets.chomp) while true } # CLI remain
Tk.mainloop
