require 'tk'
require 'byebug'

# Root window
root = TkRoot.new(title: "N++ Custom Userlevel Search Engine")

# Variables holding values of widgets
vTitleText = TkVariable.new("Title")
vTitleBox  = TkVariable.new(false)

# Widgets
wTitleText  = TkEntry.new(root, textvariable: vTitleText, state: vTitleBox == true ? "normal" : "disabled")
wTitleBox   = TkCheckButton.new(root, variable: vTitleBox, command: ->{ wTitleText.state = vTitleBox == false ? "disabled" : "normal" })

# Layout
wTitleBox.pack(side: "left")
wTitleText.pack(side: "left")

# Start GUI loop
Tk.mainloop
