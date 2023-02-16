require 'tk'
#require 'tkextlib/tkimg'
require 'byebug'

INITIAL_DATE = Time.new(2015, 6, 2)

$config = {}
$filters = {}

# Search profiles
class Search
  attr_accessor :name, :filters, :states, :hidden
  @@searches = {}  # Hash of search profiles
  @@list     = nil # TkListbox
  @@entry    = nil # TkEntry

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

  def self.draw(frame)
    @@entry = TkEntry.new(frame).grid(sticky: 'ew')
    @@list  = TkListbox.new(frame, selectmode: 'browse', width: 10, height: 6).grid(sticky: 'ew')
    @@list.bind('<ListboxSelect>', ->{ update_entry; load })
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
    name.strip!
    name = 'Unnamed' if name.empty?
    name.gsub!(/\(\d+\)$/, '')
    matches = @@searches.keys.select{ |n| n == name || n =~ /^#{name} \(\d+\)$/ } 
    return name if matches.empty?
    index = [(matches.map{ |n| n[/\((\d+)\)$/, 1].to_i }.max || 1) + 1, 2].max
    return "#{name} (#{index})"
  end

  def self._load(name)
    return if !@@searches.key?(name)
    Filter.update(@@searches[name].filters, @@searches[name].states)
  end

  def self.load
    selection = @@list.curselection[0]
    return if selection.nil?
    name = @@list.get(selection)
    return if name.nil?
    _load(name)
  end

  # TODO: Dialog for confirmation in case of same name instead of return
  def self.save
    name = find_name(@@entry.value)
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
  end

  def self.update_entry
    selection = @@list.curselection[0]
    return if selection.nil?
    name = @@list.get(selection)
    return if !@@searches.key?(name)
    @@entry.value = name
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
    @label.place(x: x, y: y) # Absolute coordinates with respect to the root window
  end

  def leave
    @label.place_forget
    @label = nil
  end
end

class Button < TkButton
  def initialize(frame, image, row, column, tooltip, command, padx = 0, pady = 0)
    super(frame, image: TkPhotoImage.new(file: image), command: command)
    self.grid(row: row, column: column, sticky: 'nsew', padx: padx, pady: pady)
    if !tooltip.nil? && !tooltip.empty? then Tooltip.new(self, tooltip) end
  end
end

# Custom class to hold a search filter
class Filter
  @@filters = {}

  def self.update(filters, states)
    filters.each{ |name, value|
      next if !@@filters.key?(name) || !states.key?(name)
      @@filters[name].update(states[name], value)
    }
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
    @is_list = value.is_a?(Array)
    @name  = name

    # Widget variables
    @vName    = TkVariable.new(name)
    @vText    = TkVariable.new(@is_list ? value[0] : value)
    @vCheck   = TkVariable.new(state)
    @vEntries = TkVariable.new(value) if @is_list

    # Widget objects
    @wName  = TkLabel.new(parent, textvariable: @vName)
    @wText  = (@is_list ? TkCombobox : TkEntry).new(parent, textvariable: @vText)
    @wText.values = value if @is_list
    @wCheck = TkCheckButton.new(parent, variable: @vCheck, command: ->{ update_state })

    # Initialize widget values to default
    update(Search.find('Sample search').states[@name], Search.find('Sample search').filters[@name])
    @@filters[@name] = self
  end

  def value
    @vText.string
  end

  def state
    @vCheck.bool
  end

  def update_state
    @wText.state = @vCheck == true ? "normal" : "disabled"
  end

  def update(state, text)
    @vCheck.bool  = state
    @vText.string = text.is_a?(Array) ? text[0] : text
    update_state
  end

  def toggle(state = nil)
    @vCheck = state.nil? ? !@vCheck : !!state
  end

  # Recover TK geometry methods
  #def pack(**args)  @wFrame.pack(args)  end
  def grid(row, col)
    @wCheck.grid(row: row, column: col,     sticky: 'ew')
    @wName.grid(row: row,  column: col + 1, sticky: 'w')
    @wText.grid(row: row,  column: col + 2, sticky: 'ew')
  end
  #def place(**args) @wFrame.place(args) end
end

# Aux functions
def format_date(date)
  date.strftime("%d/%m/%Y")
end

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
      'Mode'       => ['Solo', 'Coop', 'Race'],
      'Tab'        => ['Best', 'Featured', 'Top Weekly', 'Hardest'],
      'Before'     => '',
      'After'      => '',
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
      'Mode'       => ['Solo', 'Coop', 'Race'],
      'Tab'        => ['Best', 'Featured', 'Top Weekly', 'Hardest'],
      'Before'     => format_date(Time.now),
      'After'      => format_date(INITIAL_DATE),
      'Min ID'     => '100000',
      'Max ID'     => '22715',
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
      'Before'     => false,
      'After'      => false,
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
      'Before'     => false,
      'After'      => false,
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
end

def info(text)
  Tk.messageBox(type: 'ok', icon: 'info', title: 'Info', message: text)
end

def warn(text)
  Tk.messageBox(type: 'ok', icon: 'warning', title: 'Warning', message: text)
end

def err(text)
  Tk.messageBox(type: 'ok', icon: 'error', title: 'Error', message: text)
end

# Root window
$root = TkRoot.new(title: "N++ Custom Userlevel Search Engine")
$root.minsize(190, 640)
$root.geometry('190x640')
$root.grid_columnconfigure(0, weight: 1)

# Initialize config and others (don't move up)
init

# Filters
fFilters = TkFrame.new($root).grid(row: 0, column: 0, sticky: 'new')
fFilters.grid_columnconfigure(2, weight: 1)
sample = Search.find('Sample search')
sample.filters.map{ |name, value|
  $filters[name] = Filter.new(fFilters, name, value, sample.states[name])
}
$filters.values.each_with_index{ |f, i| f.grid(i, 0) }

# Search
fButtons = TkFrame.new($root).grid(row: 1, column: 0, sticky: 'w')
Button.new(fButtons, 'icons/new.gif',    0, 0, 'New',    ->{ Search.clear })
Button.new(fButtons, 'icons/save.gif',   0, 1, 'Save',   ->{ Search.save })
Button.new(fButtons, 'icons/delete.gif', 0, 2, 'Delete', ->{ Search.delete })
Button.new(fButtons, 'icons/search.gif', 0, 3, 'Search', ->{ })
Button.new(fButtons, 'icons/npp.gif',    0, 4, 'Play',   ->{ })
fSearch = TkFrame.new($root).grid(row: 2, column: 0, sticky: 'new')
fSearch.grid_columnconfigure(0, weight: 1)
Search.draw(fSearch)

# Navigation
fButtons2 = TkFrame.new($root).grid(row: 3, column: 0, sticky: 'w')
Button.new(fButtons2, 'icons/first.gif',    0, 0, 'First',    -> { })
Button.new(fButtons2, 'icons/previous.gif', 0, 1, 'Previous', -> { })
Button.new(fButtons2, 'icons/next.gif',     0, 2, 'Next',     -> { })
Button.new(fButtons2, 'icons/last.gif',     0, 3, 'Last',     -> { })

# Start program
Tk.mainloop
