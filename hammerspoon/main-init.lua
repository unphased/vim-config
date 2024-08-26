-- hs.ipc.cliInstall()
hs.loadSpoon("EmmyLua")

local home = os.getenv("HOME")

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
    local instances = {hs.application.find('com.neovide.neovide')}
    print("Found " .. #instances .. " Neovide instance(s)")
    return instances
end

-- there are 2 impls of this list fetch because the one ordered by access time is probably slower
local function findNeovideInstancesAccessOrder()
    print("Listing Neovides by window order...")
    local instances = {}
    local orderedWindows = hs.window.orderedWindows()
    for _, window in ipairs(orderedWindows) do
        local app = window:application();
        if app:bundleID() == 'com.neovide.neovide' then
            table.insert(instances, app)
        end
    end
    return instances
end

-- Get the working directory of a Neovide instance
local function getNeovideWorkingDir(pid)
    print("Getting working directory for Neovide with PID: " .. pid)
    -- uh so we have to get the second child to get the nvim, since the first child is just a shell
    local nvimShellPid = hs.execute(string.format("pgrep -P %d", pid)):gsub("\n", "")
    local nvimPid = hs.execute(string.format("pgrep -P %s", nvimShellPid)):gsub("\n", "")
    if nvimPid ~= "" then
        print("Found Neovim PID: " .. nvimPid)
        local cwd = hs.execute(string.format("lsof -a -p %s -d cwd -F n | tail -n1 | sed 's/^n//'", nvimPid)):gsub("\n$", "")
        print("Working directory: " .. cwd)
        return cwd:gsub('^' .. home, "~")
    end
    print("Failed to get working directory")
    return nil
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
            print("Found file: " .. file.name .. ' with time ' .. file.modTime)
            local s = file.name:gsub("__", "/"):gsub('^' .. home, "~")
            print("Converted to: " .. s)
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
    print("Getting all sessions...")
    local sessions = {}
    local runningPaths = {}

    -- Add running Neovide instances
    local neovideInstances = findNeovideInstancesAccessOrder()
    for _, app in ipairs(neovideInstances) do
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

    -- Add session files that are not already running
    local sessionFiles = findSessionFiles()
    for _, file in ipairs(sessionFiles) do
        if not runningPaths[file] then
            table.insert(sessions, {
                type = "file",
                focused = false,
                path = file
            })
            print("Added session file: " .. file)
        else
            print("Skipped session file (already running): " .. file)
        end
    end

    print("Total unique sessions found: " .. #sessions)
    print("Dumping sessions:", hs.inspect(sessions))
    return sessions
end

--- @type nil | hs.chooser
local openChooser = nil
local function neovideSessions()
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
        print("Creating chooser item: " .. text .. " (" .. subText .. ")")
        return {
            text = text,
            subText = subText,
            valid = not session.focused,
            session = session
        }
    end)
    print('items:', hs.inspect(items))

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
    chooser:invalidCallback(function ()
        print("Invalid callback called")
    end)
    chooser:choices(items)
    chooser:show()
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
    local neovideInstances = findNeovideInstances()
    local focusedWindow = hs.window.focusedWindow()
    local focusedApp = focusedWindow and focusedWindow:application()

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

hs.hotkey.bind({"alt"}, "space", function()
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

-- local function getMarkdownFiles(directory)
--     local files = hs.fs.dir(directory)
--     local markdownFiles = {}
--     for file in files do
--         if file:match("%.md$") then
--             table.insert(markdownFiles, file)
--         end
--     end
--     return markdownFiles
-- end
--
-- local function createButtonsFromFiles(files)
--     local buttons = {}
--     for i, file in ipairs(files) do
--         local button = {
--             title = file:gsub("%.md$", ""),
--             fn = function()
--                 hs.execute(string.format('open "%s/util/prompts/%s"', home, file))
--             end
--         }
--         table.insert(buttons, button)
--     end
--     return buttons
-- end
--
-- hs.hotkey.bind({"cmd", "shift", "alt"}, "X", function()
--     hs.execute('bash -c "/usr/sbin/screencapture -i /tmp/screencap.png"')
--
--     local image = hs.image.imageFromPath("/tmp/screencap.png")
--     if image then
--         local imageView = hs.webview.newBrowser({x = 100, y = 100, w = 640, h = 480})
--         imageView:url("file:///tmp/screencap.png")
--         imageView:show()
--
--         local promptsDir = home .. "/util/prompts"
--         local markdownFiles = getMarkdownFiles(promptsDir)
--         local buttons = createButtonsFromFiles(markdownFiles)
--
--         local chooser = hs.chooser.new(function(choice)
--             if choice then
--                 choice.fn()
--             end
--             imageView:delete()
--         end)
--
--         chooser:choices(buttons)
--         chooser:show()
--     else
--         hs.alert.show("Failed to capture screenshot")
--     end
-- end)

hs.alert.show("Hammerspoon config loaded")