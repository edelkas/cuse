require 'tk'
require 'byebug'

# Root window
root = TkRoot.new(title: "N++ Custom Userlevel Search Engine")
root.minsize(480, 480)
root.geometry('480x480')
root.grid_columnconfigure(0, weight: 1)

# Custom class to hold a search filter
class Filter
  def initialize(parent, value, active)
    is_list = value.is_a?(Array)

    # Create variables
    @vText    = TkVariable.new(is_list ? value[0] : value)
    @vCheck   = TkVariable.new(active)
    @vEntries = TkVariable.new(value) if is_list

    # Create widgets
    @wFrame = TkFrame.new(parent)
    @wText  = (is_list ? TkCombobox : TkEntry).new(@wFrame, textvariable: @vText, state: state)
    @wText.values = value if is_list
    @wCheck = TkCheckButton.new(@wFrame, variable: @vCheck, command: ->{ @wText.state = state })

    # Place widgets
    @wCheck.pack(side: 'left')
    @wText.pack(side: 'left', fill: 'x', expand: 1)
  end

  def state
    @vCheck == true ? "normal" : "disabled"
  end

  # Recover TK geometry methods
  def pack(**args)  @wFrame.pack(args)  end
  def grid(**args)  @wFrame.grid(args)  end
  def place(**args) @wFrame.place(args) end
end

# Create search filter fields
filters = [
  'Title',
  'Author',
  ['All', 'Solo', 'Coop', 'Race']
].map{ |f| Filter.new(root, f, false) }

# Place fields
filters.each_with_index{ |f, i| f.grid(row: i, column: 0, sticky: 'ew') }

# Start GUI loop
Tk.mainloop
