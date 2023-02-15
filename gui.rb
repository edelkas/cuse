require 'tk'
#require 'tkextlib/tkimg'
require 'byebug'

INITIAL_DATE = Time.new(2015, 6, 2)

$config = {}
$filters = {}

# Search profiles
class Search
  attr_accessor :name, :filters, :hidden
  @@searches = {}
  @@list = nil

  # Default searches
  def self.init
    @@searches['Current']       = Search.new('Current',       $config[:filters_default].dup, true, false)
    @@searches['Sample search'] = Search.new('Sample search', $config[:filters_default].dup, false, false)
    @@searches['Empty']         = Search.new('Empty',         $config[:filters_empty].dup,   true, false)
  end

  def self.draw(frame)
    @@list = TkListbox.new(frame, selectmode: 'single', width: 10, height: 6).grid(sticky: 'ew')
    update
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

  def self.load(name)
    return if !@@searches.key?(name)
    @@searches['Current'].filters = @@searches[name].filters.dup
  end

  def self.save(name)
    name = find_name(name)
    @@searches[name] = Search.new(name, @@searches['Current'].filters.dup, false, true)
    update
  end

  def self.delete
    selection = @@list.curselection[0]
    return if selection.nil?
    find(@@list.get(selection)).delete
  end

  def self.update
    @@list.value = @@searches.values.select{ |s| !s.hidden }.map(&:name)
  end

  # TODO: Add confirmation dialog
  def delete
    return if !@deletable
    @@searches.delete(@name)
    self.class.update
  end

  def edit(new_name)
    return if @@searches.key?(new_name)
    @@searches[new_name] = @@searches.delete(@name)
    self.class.update
  end

  def initialize(name, filters, hidden = false, deletable = true)
    @name      = name
    @filters   = filters
    @hidden    = hidden
    @deletable = deletable
    @@searches[@name] = self
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

  def self.update(search)
    return if Search.find(search).nil?
    Search.find(search).filters.each{ |name, filter|
      next if !@@filters.key?(name)
      @@filters[name].update(false, filter)
    }
  end

  def self.reset
    @@filters.each{ |name, filter| filter.reset }
  end

  def self.clear
    @@filters.each{ |name, filter| filter.clear }
  end

  def initialize(parent, name, value, active)
    @is_list = value.is_a?(Array)

    # Factory values
    @name   = name
    @value  = value
    @active = active

    # Create variables
    @vName    = TkVariable.new(@name)
    @vText    = TkVariable.new(@is_list ? @value[0] : @value)
    @vCheck   = TkVariable.new(@active)
    @vEntries = TkVariable.new(@value) if @is_list

    # Create widgets
    @wName  = TkLabel.new(parent, textvariable: @vName)
    @wText  = (@is_list ? TkCombobox : TkEntry).new(parent, textvariable: @vText)
    @wText.values = value if @is_list
    @wCheck = TkCheckButton.new(parent, variable: @vCheck, command: ->{ update_state })

    # Initialize widget values to default
    reset
    @@filters[@name] = self
  end

  def update_state
    @wText.state = @vCheck == true ? "normal" : "disabled"
  end

  def update(state, text)
    @vCheck.bool  = state
    @vText.string = @is_list ? text[0] : text
    update_state
  end

  def reset
    update(@active, Search.find('Sample search').filters[@name])
  end

  def clear
    update(false, Search.find('Empty').filters[@name])
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

# Frames
fFilters = TkFrame.new($root).grid(row: 0, column: 0, sticky: 'new')
fButtons = TkFrame.new($root).grid(sticky: 'w')

# Initialize config and others (don't move up)
init

# Filters
fFilters.grid_columnconfigure(2, weight: 1)
Search.find('Sample search').filters.map{ |name, value|
  $filters[name] = Filter.new(fFilters, name, value, name == 'Title' ? true : false)
}
$filters.values.each_with_index{ |f, i| f.grid(i, 0) }

# Search
vSearch = TkVariable.new('')
wSearch = TkEntry.new($root, textvariable: vSearch)
Button.new(fButtons, 'icons/new.gif',    0, 0, 'New',    ->{ Filter.clear })
Button.new(fButtons, 'icons/load.gif',   0, 1, 'Load',   ->{})
Button.new(fButtons, 'icons/edit.gif',   0, 2, 'Edit',   ->{})
Button.new(fButtons, 'icons/save.gif',   0, 3, 'Save',   ->{ Search.save(vSearch.to_s) })
Button.new(fButtons, 'icons/delete.gif', 0, 4, 'Delete', ->{ Search.delete })
wSearch.grid(sticky: 'ew')
Search.draw($root)

# Buttons
bSearch = TkButton.new($root, text: 'Search').grid(sticky: 'ew')

# Start program
Tk.mainloop
