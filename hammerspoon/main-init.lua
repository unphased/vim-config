-- hs.ipc.cliInstall()
hs.loadSpoon("EmmyLua")

local home = os.getenv("HOME")

local socket = require "socket"
local function dump(o)
   if type(o) == 'table' then
      local s = '{ '
      for k,v in pairs(o) do
         if type(k) ~= 'number' then k = '"'..k..'"' end
         s = s .. '['..k..'] = ' .. dump(v) .. ','
      end
      return s .. '} '
   else
      return tostring(o)
   end
end

_G.l = function(...)
  local args = {...}
  local log_file_path = "/tmp/lua-hs.log"
  local log_file = io.open(log_file_path, "a")
  if log_file == nil then
    print("Could not open log file: " .. log_file_path)
    return
  end
  io.output(log_file)
  io.write(socket.gettime() .. " >>> ")
  for i, payload in ipairs(args) do
    local ty = type(payload)
    if ty == "table" then
      io.write(string.format("%d -> %s\n", i, dump(payload)))
    elseif ty == "function" then
      io.write(string.format("%d -> [function]\n", i))
    else
      io.write(string.format("%d -> %s\n", i, payload))
    end
  end
  io.close(log_file)
end
l('running main-init.lua');

-- SESSION TRIGGER CONCEPT
-- * find existing sessions files as maintained by neovim-session-manager in their default location
-- * find running neovide instances
-- * present a picker list containing the union of above (note this means neovims open in dirs without established
-- sessions will also be listed)
-- * on selection, focus or open a neovide on the selected dir
-- * TODO also find and list running non neovide neovim instances, identify if they are running in tmux, identify
-- running terminals connected to tmux, focus those terminal apps and focus the tmux onto the corresponding
-- session/window/pane. Yea this would be quite a lot...

-- details: finding the session of a running instance
-- * we aim to perform a union based on session path
-- * hs grabs pid of neovide -> pgrep -P to look for child nvim pid -> lsof with nvim pid to get cwd.

-- GO TO EDITOR CONCEPT
-- if there exists zero neovide instances open, perform session trigger to choose a session to open (OR: open the most
-- recently opened session, let's see)
-- else if already focused on a neovide instance, perform the session trigger (self would be included, greyed, in the list)
--      else (not focused):
--          if one instance exists, focus it
--          else more than one instance exists, focus the most recently focused one

-- Helper functions

-- Find all running Neovide instances
local function findNeovideInstances()
    print("Finding Neovide instances...")
    local allApps = hs.application.runningApplications()
    local instances = {}
    
    for _, app in ipairs(allApps) do
        if app:bundleID() == 'com.neovide.neovide' then
            table.insert(instances, app)
        end
    end
    
    print(string.format("Found %d Neovide instances", #instances))
    
    -- Debug each instance
    for i, instance in ipairs(instances) do
        print(string.format("Instance %d: %s (PID: %d)", i, instance:name(), instance:pid()))
        print("  Bundle ID:", instance:bundleID())
        print("  Is running:", instance:isRunning())
    end
    
    return instances
end

-- Get the working directory of a Neovide instance
local function getNeovideWorkingDir(pid)
    print("Getting working directory for PID:", pid)
    
    -- Use ps to find the nvim child process
    local psCmd = string.format("ps -o ppid,pid,command -p %d", pid)
    local output = hs.execute(psCmd)
    print("ps output:", output)
    
    -- Get all descendant processes
    local childCmd = string.format("ps -o pid,ppid,command -p $(pgrep -d, -P %d) $(pgrep -d, -P $(pgrep -P %d))", pid, pid)
    local childOutput = hs.execute(childCmd)
    print("Child processes:", childOutput)
    
    -- Find the actual nvim process (not the login process)
    local nvim_pid = nil
    local login_pid = nil
    for line in childOutput:gmatch("[^\n]+") do
        local pid, ppid, cmd = line:match("(%d+)%s+(%d+)%s+(.+)")
        if pid and cmd:match("/nvim.*--embed") then
            nvim_pid = pid
            login_pid = ppid  -- Store the login process PID
            break
        end
    end
    print("Found Nvim PID:", nvim_pid)
    print("Login PID:", login_pid)
    
    if not nvim_pid then 
        print("Failed to find nvim PID")
        return nil 
    end
    
    -- Get working directory using lsof on the nvim process, not the login process
    local lsofCmd = string.format("lsof -p %s | awk '$4==\"cwd\" {print $9}'", nvim_pid)
    local cwd = hs.execute(lsofCmd):gsub("\n$", "")
    print("lsof command:", lsofCmd)
    print("Raw cwd result:", cwd)
    
    if cwd == "" then
        print("Could not determine working directory")
        return nil
    end
    
    local final_path = cwd:gsub('^' .. home, "~")
    print("Final path:", final_path)
    return final_path
end

-- Find existing session files
local function findSessionFiles()
    print("Finding session files...")
    local sessionDir = home .. "/.local/share/nvim/sessions"
    local sessions = {}
    if hs.fs.attributes(sessionDir, "mode") == "directory" then
        local files = {}
        for file in hs.fs.dir(sessionDir) do
            if file ~= "." and file ~= ".." then
                local fullPath = sessionDir .. "/" .. file
                local modTime = hs.fs.attributes(fullPath, "modification")
                table.insert(files, {name = file, modTime = modTime})
            end
        end
        table.sort(files, function(a, b) return a.modTime > b.modTime end)
        for _, file in ipairs(files) do
            -- print("Found file: " .. file.name .. ' with time ' .. file.modTime)
            local s = file.name:gsub("__", "/"):gsub('^' .. home, "~")
            -- print("Converted to: " .. s)
            table.insert(sessions, s)
        end
    else
        print("Session directory not found: " .. sessionDir)
        hs.alert.show("Session directory not found: " .. sessionDir)
    end
    print("Found " .. #sessions .. " file(s)")
    return sessions
end

-- Combine Neovide instances and session files
local openChooserInstanceCount = 0
local function getAllSessions()
    l('gAS')
    print("Getting all sessions...")
    local sessions = {}
    local runningPaths = {}
    print("Starting with empty runningPaths table")

    local function printRunningPaths()
        print("Current runningPaths contents:")
        for path, _ in pairs(runningPaths) do
            print("  - " .. path)
        end
    end

    -- Add running Neovide instances
    local neovideInstances = findNeovideInstances()
    l('gAS 1')
    print("Found " .. #neovideInstances .. " Neovide instances")
    -- Debug output for each instance
    for i, app in ipairs(neovideInstances) do
        print(string.format("Neovide instance %d: PID=%d", i, app:pid()))
    end
    for i, app in ipairs(neovideInstances) do
        print("Processing Neovide instance " .. i .. " with PID: " .. app:pid())
        local cwd = getNeovideWorkingDir(app:pid())
        if cwd then
            table.insert(sessions, {
                type = "running",
                focused = app:isFrontmost(),
                path = cwd,
                app = app
            })
            runningPaths[cwd] = true
            print("Added running Neovide instance: " .. cwd)
        else
            print("Warning: Could not get working directory for Neovide instance with PID: " .. app:pid())
        end
    end
    openChooserInstanceCount = #neovideInstances
    l('gAS 2')

    -- Print summary of running instances
    printRunningPaths()

    -- Add session files that are not already running
    local sessionFiles = findSessionFiles()
    l('gAS 3')
    for _, file in ipairs(sessionFiles) do
        -- print("Checking session file: " .. file)
        -- print("Is it in runningPaths? " .. tostring(runningPaths[file] == true))
        if not runningPaths[file] then
            table.insert(sessions, {
                type = "file",
                focused = false,
                path = file
            })
            -- print("Added session file: " .. file)
        else
            print("Skipped session file (already running): " .. file)
        end
    end
    l('gAS 4')

    print("Total unique sessions found: " .. #sessions)
    -- print("Dumping sessions:", hs.inspect(sessions))
    return sessions
end

--- @type nil | hs.chooser
local openChooser = nil
local function neovideSessions()
    l(5)
    print("Starting neovideSessions function...")
    local sessions = getAllSessions()
    local hasAFocusedNeovide = false
    local items = hs.fnutils.imap(sessions, function(session)
        local invalid = not not session.focused;
        if invalid then
            print('has a focused neovim, it is the session ' .. session.path)
            hasAFocusedNeovide = true
        end
        local text = invalid and hs.styledtext.new(session.path .. " (current)", {
            color = { hex = "#5F5050", alpha = 1 },
        }) or session.path or "Unknown path"
        local subText = session.type == "running" and "Running" or "Session file"
        -- print("Creating chooser item: " .. text .. " (" .. subText .. ")")
        return {
            text = text,
            subText = subText,
            valid = not session.focused,
            session = session
        }
    end)
    -- print('items:', hs.inspect(items))
    l(6)

    local callback = function(choice)
        openChooser = nil
        openChooserInstanceCount = 0
        if choice then
            print("User selected: " .. choice.text)
            if choice.session.type == "running" then
                print("Activating running Neovide instance")
                choice.session.app:activate()
            else
                print("Launching Neovide at: " .. choice.session.path)
                launchNeovideAtDir(choice.session.path)
            end
        else
            print("User cancelled selection")
        end
    end

    print("Showing chooser with " .. #items .. " items")
    local chooser = hs.chooser.new(callback)
    l(7)
    chooser:invalidCallback(function ()
        print("Invalid callback called")
    end)
    chooser:choices(items)
    chooser:show()
    l(8)
    openChooser = chooser
    if hasAFocusedNeovide then
        chooser:selectedRow(2)
    end
end

hs.hotkey.bind("Ctrl-Cmd", "S", function()
    -- special contextual behavior -- if i'm trying to mash the key and the menu is already open, choose the selected
    -- item (usually the 2nd item) but only if it is an open instance, e.g. if 2 or more instances are already open,
    -- otherwise close the chooser instead of selecting the selected one.
    if openChooser then
        if openChooserInstanceCount > 1 then
            openChooser:select()
            return
        else
            openChooser:cancel()
            return
        end
    end
    l(1)
    local neovideInstances = findNeovideInstances()
    l(2)
    local focusedWindow = hs.window.focusedWindow()
    l(3)
    local focusedApp = focusedWindow and focusedWindow:application()
    l(4)

    -- No Neovide instances open, perform session trigger
    if #neovideInstances == 0 or (focusedApp and focusedApp:bundleID() == 'com.neovide.neovide') then
        -- Already focused on a Neovide instance, perform session trigger
        neovideSessions()
    else
        -- Not focused on Neovide, but instances exist
        if #neovideInstances == 1 then
            -- Only one instance, focus it
            neovideInstances[1]:activate()
        else
            -- Multiple instances, focus the most recently focused one. iterate through orderedwindows to get there.
            local orderedWindows = hs.window.orderedWindows()
            for _, window in ipairs(orderedWindows) do
                if window:application():bundleID() == 'com.neovide.neovide' then
                    print('activating a neovide instance during orderedWindows iteration.')
                    window:application():activate()
                    break
                end
            end
        end
    end
end)

function launchNeovideAtDir(path)
    print("Launching Neovide at path: " .. path)
    os.execute("pushd " .. path .. "; PATH=$HOME/.cargo/bin:$PATH /opt/homebrew/bin/neovide &")
end

hs.hotkey.bind({"shift", "cmd"}, "space", function()
    print("Alt+Space hotkey triggered")
    local nv = hs.application.get("com.neovide.neovide")
    if nv then
        print("Neovide instance found")
        print("Type of nv:", type(nv))
        print("nv is", nv)
        if nv:isFrontmost() then
            print("Neovide is frontmost, hiding")
            nv:hide()
        else
            print("Neovide is not frontmost, activating")
            nv:activate()
        end
    else
        print("No Neovide instance found, launching new one")
        launchNeovideAtDir(home .. "/.vim")
    end
end)

local currentFilePath = debug.getinfo(1, "S").source:sub(2)
local currentDir = currentFilePath:match("(.*/)") or ""
local windowWatcher = dofile(currentDir .. "window-watcher.lua")
local function ai_screenshot()
    local image = hs.image.imageFromPath("/tmp/screencap.png")
    if image then
        local size = image:size()
        local imageView = hs.webview.newBrowser({x = 0, y = 0, w = size.w, h = size.h})
        if imageView == nil then return end
        imageView:shadow(true)

        windowWatcher.specifyRelatedWebView(imageView, function(win)
            print("Terminal window closed, deleting imageView")
            imageView:delete()
        end)

        imageView:url("file:///tmp/screencap.png")
        imageView:show()

        -- local cmd = 'open ' .. home .. '/util/AI\\ screen\\ help.terminal'
        local cmd = 'open -a iTerm ' .. home .. '/util/screenshot-to-aichat'
        print('running cmd '.. cmd)
        hs.execute(cmd)
    else
        hs.alert.show("Failed to capture screenshot")
    end
end

-- perform a screenshot snap. It goes to the special single place I manage screenshots at. Used for aider workflows too.
hs.hotkey.bind({"option", "shift"}, "W", function ()
    print('making just a screenshot')
    hs.execute('bash -c "/usr/sbin/screencapture -i /tmp/screencap.png"')
end)

-- automated screenshot taking followed by sending to ai tool. can dismiss screenshot to use previous snap.
hs.hotkey.bind({"cmd", "shift", "alt"}, "X", function()
    print('making a screenshot')
    hs.execute('bash -c "/usr/sbin/screencapture -i /tmp/screencap.png"')
    print('launching ai')
    ai_screenshot()
end)

hs.hotkey.bind({"option", "shift"}, "R", function ()
    print('making a screenshot')
    hs.execute('bash -c "/usr/sbin/screencapture -i $HOME/automated_screencaps/$(date +%s).png"')
end)

-- Variable to store the timestamp of the last Shift+Option+Y press
local lastShiftOptYPress = os.time()

hs.hotkey.bind({"option", "shift"}, "Y", function ()
    local currentTime = os.time()
    local cmd = string.format(home .. '/util/imgcat-to-aichat.sh %d', lastShiftOptYPress)
    print('running cmd ' .. cmd)
    hs.execute(cmd)
    lastShiftOptYPress = currentTime
    -- now the image has been prepped.
    ai_screenshot()
end)

hs.alert.show("Main hammerspoon config loaded")
