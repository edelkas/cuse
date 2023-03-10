require 'tk'
require 'date'
require 'zlib'
#require 'tkextlib/tkimg'
#require 'tkextlib/iwidgets'
require 'byebug'

DEFAULT_SEARCH  = "Unnamed search"
INITIAL_DATE    = Date.new(2015, 6, 2)
DATE_FORMAT     = "%d/%m/%Y"
TIME_FORMAT_IN  = "%Y-%m-%d-%H:%M"
TIME_FORMAT_OUT = "%d/%m/%Y %H:%M"
TIME_FORMAT_LOG = "%H:%M:%S"

COLOR_LOG_NORMAL  = "#000"
COLOR_LOG_WARNING = "#F70"
COLOR_LOG_ERROR   = "#F00"

$config  = {}
$filters = {}

# Aux functions
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
  bytes.unpack('H*')[0].scan(/../).reverse.join.to_i(16)
end

def to_utf8(str)
  str.bytes.reject{ |b| b < 32 || b == 127 }.join.scrub('_')
end

def parse_date(str)
  Date.strptime(str, DATE_FORMAT) rescue nil
end

def format_date(date)
  date.strftime(DATE_FORMAT)
end

def parse_time(str)
  DateTime.strptime(str, TIME_FORMAT_IN) rescue nil
end

def format_time(time)
  time.strftime(TIME_FORMAT_OUT)
end

class Tooltip
  def initialize(widget, text = " ? ")
    @wait       = 2000 # not in use, 'after' didnt work
    @wraplength = 180
    @widget     = widget
    @text       = text
    @label      = nil
    @schedule   = nil # not in use, 'after' didnt work
    @widget.bind('Enter'){ enter }
    @widget.bind('Leave'){ leave }
  end

  def enter
    # Absolute coordinates of pointer with respect to screen minus the same for the root window
    # equals absolute coordinates of pointer with respect to the root window
    x = @widget.winfo_pointerx - $root.winfo_rootx + 10
    y = @widget.winfo_pointery - $root.winfo_rooty + 10
    @label = TkLabel.new($root, text: @text, justify: 'left', background: "#ffffff", relief: 'solid', borderwidth: 1, wraplength: @wraplength)
    @label.place(in: @widget, x: 0, y: @widget.winfo_height) # Absolute coordinates with respect to the root window
  end

  def leave
    @label.place_forget
    @label = nil
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
end

# Search profiles
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
      $config[:filters_default].dup,
      $config[:states_default].dup,
      false,
      false
    )
    @@searches['Empty'] = Search.new(
      'Empty',
      $config[:filters_empty].dup,
      $config[:states_empty].dup,
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
  end

  def self.save
    name = find_name(@@entry.value)
    Filter.validate
    @@searches[name] = Search.new(name, Filter.filters, Filter.states, false, true)
    update_list
  end

  def self.delete
    selection = @@list.curselection[0]
    return if selection.nil?
    name = @@list.get(selection)
    return if !@@searches.key?(name)
    @@searches[@@list.get(selection)].delete
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

  def self.execute
    Filter.validate
  end

  def initialize(name, filters, states, hidden = false, deletable = true)
    @name      = name
    @filters   = filters
    @states    = states
    @hidden    = hidden
    @deletable = deletable
    @@searches[@name] = self
  end

  # TODO: Add confirmation dialog
  def delete
    return if !@deletable
    @@searches.delete(@name)
    self.class.update_list
  end

  # Create copy of search (same filters and states)
  def dup(name, hidden = false, deletable = true)
    return if @@searches.key?(name)
    @@searches[name] = Search.new(name, @filters.dup, @states.dup, hidden, deletable)
  end
end # End Search

# Custom class to hold a search filter
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
      @wText = TkSpinbox.new(parent, textvariable: @vText, from: 0, to: 20, state: 'readonly', repeatdelay: 100, repeatinterval: 25, readonlybackground: 'white')
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
  attr_reader :levels

  @@tree      = nil # Tk::Tile::Treeview containing levels
  @@active    = nil # Currently active/visible instance of LevelSet
  @@sets      = []  # Array of instances
  @@charwidth = 9   # Average font char size of elements
  @@minwidth  = 12   # Average font char size of headers
  @@fields    = {
    'id'     => { anchor: 'e', width: 7  },
    'title'  => { anchor: 'w', width: 16 },
    'author' => { anchor: 'w', width: 16 },
    'date'   => { anchor: 'w', width: 16 },
    '++'     => { anchor: 'e', width: 3  }
  }
  
  def self.init(frame, row, col)
    @@tree = TkTreeview.new(
      frame,
      selectmode: 'browse',
      height:     25,
      columns:    @@fields.keys.join(' '),
      show:       'headings'
    ).grid(row: row, column: col, sticky: 'news')
    @@fields.each{ |name, attr|
      @@tree.column_configure(name, anchor: attr[:anchor], minwidth: name.length * @@minwidth, width: attr[:width] * @@charwidth)
      @@tree.heading_configure(name, text: name.capitalize)
    }
  end

  def self.update_tree
    @@tree.children.each(&:delete)
    return if @@active.nil?
    @@active.levels.each{ |l|
      @@tree.insert('', 'end', values: @@fields.keys.map{ |f| l[f] })
    }
  end

  def initialize(search, raw)
    @search = search
    @header = {}
    @levels = []
    parse(raw)
    @@sets << self
    activate
    self.class.update_tree
  end

  def activate
    @@active = self
  end

  def parse(raw)
    # Parse header
    return if raw.size < 48
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
    return if raw.size < 48 + 44 * @header[:count]
    @levels = raw[48 ... 48 + 44 * @header[:count]].bytes.each_slice(44).map { |h|
      {
        'id'        => _unpack(h[0...4], 'l<'),
        'author_id' => _unpack(h[0...8], 'l<'),
        'author'    => to_utf8(h[8...24].split("\x00")[0]).strip,
        '++'        => _unpack(h[24...28], 'l<'),
        'date'      => parse_time(h[28..-1])
      }
    }

    # Parse map data
    i = 0
    offset = 48 + 44 * @header[:count]
    while i < @header[:count]
      break if raw.size < offset + 6
      len = _unpack(raw[offset...offset + 4])
      @levels[i]['count'] = _unpack(raw[offset + 4...offset + 6])
      break if raw.size < offset + len
      map = Zlib::Inflate.inflate(raw[offset + 6...offset + len])
      @levels[i]['title'] = to_utf8(map[30...158].split("\x00")[0]).strip
      @levels[i]['tiles'] = map[176...1142].bytes.each_slice(42).to_a
      @levels[i]['objects'] = map[1222..-1].bytes.each_slice(5).to_a
      offset += len
      i += 1
    end
  end

  def update_labels
    
  end
end # End LevelSet

class Log
  @@log    = nil # TkText widget to store the info
  @@scroll = nil # TkScrollbar widget for the text widget
  @@frame  = nil # TkFrame to hold the widgets

  def self.init(frame, row, col)
    @@log = Scrollable.new(frame, row, col) do |f|
      TkText.new(f, font: 'TkDefaultFont 8', foreground: COLOR_LOG_NORMAL, state: 'disabled', height: 8, wrap: 'char')
    end
    @@log.widget.tag_configure('error', foreground: COLOR_LOG_WARNING)
    @@log.widget.tag_configure('warning', foreground: COLOR_LOG_ERROR)
  end

  def self.log(type, text, tag = '')
    @@log.widget.configure(state: 'normal')
    @@log.widget.insert('end', "[#{Time.now.strftime(TIME_FORMAT_LOG)}] #{type}#{type.empty? ? '' : ': '}#{text}\n", tag)
    @@log.widget.configure(state: 'disabled')
    @@log.widget.see('end - 2l')
    @@log.update
  end

  def self.info(text)
    log('', text)
  end

  def self.warn(text)
    log('Warning', text, 'warning')
  end

  def self.err(text)
    log('Error', text, 'error')
  end
end # End Log

# Load and save config
def load_config(name = nil)
  # Actually load from config file here if it exists
  return if !name.nil?
  # If no config name is provided, load defaults
  $config = {
    filters_empty: {
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
    filters_default: {
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
    states_empty: {
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
    },
    states_default: {
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
end

def save_config(name)
end

def init
  load_config
  Search.init
  Tk::Tile::Style.configure('Treeview', rowheight: 12, font: 'Courier 9', background: "#FDD", fieldbackground: "#FDD")
  Tk::Tile::Style.configure('Heading', font: 'TkDefaultFont 10')
end

# Switch focus to root if we click outside of a widget
# This is important because we use it to validate the fields automatically
# when clicking outside of them.
def defocus(event)
  focused = Tk.focus
  return nil if focused == $root
  x1 = focused.winfo_rootx
  x2 = focused.winfo_rootx + focused.winfo_width
  y1 = focused.winfo_rooty
  y2 = focused.winfo_rooty + focused.winfo_height
  $root.focus if event.x_root < x1 || event.x_root > x2 || event.y_root < y1 || event.y_root > y2
end

# Root window
$root = TkRoot.new(title: "N++ Custom Userlevel Search Engine")
w, h = 720, 640
$root.minsize(w, h)
$root.geometry("#{w}x#{h}")
$root.grid_columnconfigure(1, weight: 1)
$root.resizable(true, false)
$root.bind('ButtonPress'){ |event| defocus(event) }

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

# Navigation
fButtons2 = TkFrame.new(fSearch).grid(row: 3, column: 0, sticky: 'w')
Button.new(fButtons2, 'icons/first.gif',    0, 0, 'First',    -> { })
Button.new(fButtons2, 'icons/previous.gif', 0, 1, 'Previous', -> { })
Button.new(fButtons2, 'icons/next.gif',     0, 2, 'Next',     -> { })
Button.new(fButtons2, 'icons/last.gif',     0, 3, 'Last',     -> { Log.info("Test") })

# Levels
LevelSet.init(fLevels, 0, 0)

# Log
Log.init(fLevels, 1, 0)
Log.info("Initialized")

# Start program
Tk.mainloop
