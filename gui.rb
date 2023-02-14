require 'tk'
require 'byebug'

INITIAL_DATE = Time.new(2015, 6, 2)

$config = {}

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
      'Title'            => '',
      'Author'           => '',
      'Author ID'        => '',
      'Mode'             => ['Solo', 'Coop', 'Race'],
      'Tab'              => ['Best', 'Featured', 'Top Weekly', 'Hardest'],
      'Date before'      => '',
      'Date after'       => '',
      'ID before'        => '',
      'ID after'         => '',
      '0th owner is'     => '',
      '0th owner is not' => '',
      'Highscore count'  => ''
    },
    filters_default: {
      'Title'            => 'Untitled',
      'Author'           => 'Melancholy',
      'Author ID'        => '117031',
      'Mode'             => ['Solo', 'Coop', 'Race'],
      'Tab'              => ['Best', 'Featured', 'Top Weekly', 'Hardest'],
      'Date before'      => format_date(Time.now),
      'Date after'       => format_date(INITIAL_DATE),
      'ID before'        => '100000',
      'ID after'         => '22715',
      '0th owner is'     => 'Slomac',
      '0th owner is not' => 'Slomac',
      'Highscore count'  => '20'
    }
  }  
end

def save_config(name)
end

# Root window
root = TkRoot.new(title: "N++ Custom Userlevel Search Engine")
root.minsize(480, 480)
root.geometry('480x480')
root.grid_columnconfigure(0, weight: 1)
load_config

# Custom class to hold a search filter
class Filter
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
    update(@active, $config[:filters_default][@name])
  end

  def clear
    update(false, $config[:filters_empty][@name])
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

# Frames
fFilters = TkFrame.new(root).grid(row: 0, column: 0, sticky: 'new')
fFilters.grid_columnconfigure(2, weight: 1)

# Search filters frame
filters = $config[:filters_default].map{
  |name, value| Filter.new(fFilters, name, value, name == 'Title' ? true : false)
}

# Place fields
filters.each_with_index{ |f, i| f.grid(i, 0) }

# Buttons
# TODO: Add load/save search, w/ Combobox and Entry resp.
wButtonSearch = TkButton.new(root, text: 'Search').grid
wButtonReset  = TkButton.new(root, text: 'Default', command: ->{ filters.each{ |f| f.reset } }).grid
wButtonClear  = TkButton.new(root, text: 'Clear', command: ->{ filters.each{ |f| f.clear } }).grid

# Start program
Tk.mainloop
