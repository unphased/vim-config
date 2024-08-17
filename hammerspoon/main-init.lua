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
    local instances = hs.application.find('com.neovide.neovide')
    local instancesTable = {}
    if instances then
        if type(instances) == "table" then
            instancesTable = instances
        else
            table.insert(instancesTable, instances)
        end
    end
    print("Found " .. #instancesTable .. " Neovide instance(s)")
    return instancesTable
end

-- Get the working directory of a Neovide instance
local function getNeovideWorkingDir(pid)
    print("Getting working directory for Neovide with PID: " .. pid)
    local nvimPid = hs.execute(string.format("pgrep -P %d", pid)):gsub("\n", "")
    if nvimPid ~= "" then
        print("Found Neovim PID: " .. nvimPid)
        local cwd = hs.execute(string.format("lsof -p %s | grep cwd | awk '{print $NF}'", nvimPid)):gsub("\n", "")
        print("Working directory: " .. cwd)
        return cwd
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
        local iter, dir_obj = hs.fs.dir(sessionDir)
        if iter then
            for file in iter, dir_obj do
                if file ~= "." and file ~= ".." then
                    local fullPath = sessionDir .. "/" .. file
                    table.insert(sessions, fullPath)
                    print("Found file: " .. file)
                end
            end
            dir_obj:close()
        end
    else
        print("Session directory not found: " .. sessionDir)
        hs.alert.show("Session directory not found: " .. sessionDir)
    end
    print("Found " .. #sessions .. " file(s)")
    return sessions
end

-- Combine Neovide instances and session files
local function getAllSessions()
    print("Getting all sessions...")
    local sessions = {}
    
    -- Add running Neovide instances
    local neovideInstances = findNeovideInstances()
    for _, app in ipairs(neovideInstances) do
        local cwd = getNeovideWorkingDir(app:pid())
        if cwd then
            table.insert(sessions, {
                type = "running",
                path = cwd,
                app = app
            })
            print("Added running Neovide instance: " .. cwd)
        end
    end
    
    -- Add session files
    local sessionFiles = findSessionFiles()
    for _, file in ipairs(sessionFiles) do
        table.insert(sessions, {
            type = "file",
            path = file:match("(.+)%.vim$")
        })
        print("Added session file: " .. file)
    end
    
    print("Total sessions found: " .. #sessions)
    return sessions
end

function neovideSessions()
    print("Starting neovideSessions function...")
    local sessions = getAllSessions()
    local items = hs.fnutils.imap(sessions, function(session)
        local text = session.path
        local subText = session.type == "running" and "Running" or "Session file"
        print("Creating chooser item: " .. text .. " (" .. subText .. ")")
        return {
            text = text,
            subText = subText,
            session = session
        }
    end)

    local callback = function(choice)
        if choice then
            print("User selected: " .. choice.text)
            if choice.session.type == "running" then
                print("Activating running Neovide instance")
                choice.session.app:activate()
            else
                print("Launching Neovide at: " .. choice.session.path)
                launch_neovide_at(choice.session.path)
            end
        else
            print("User cancelled selection")
        end
    end

    print("Showing chooser with " .. #items .. " items")
    hs.chooser.new(callback):choices(items):show()
end

hs.hotkey.bind("Ctrl-Cmd", "S", neovideSessions)

function cycleNeovideWindows()
    print("Starting cycleNeovideWindows function...")
    local current = hs.window.focusedWindow()
    print("Current focused window: " .. (current and current:title() or "None"))

    local items = hs.fnutils.imap({hs.application.find('com.neovide.neovide')}, function(app)
        local title = app:title()
        local status
        local win = app:mainWindow()

        if win ~= nil then
            title = win:title()
        end

        if win == current then
            status = '[CURRENT]'
        end

        print("Creating chooser item: " .. title .. (status and (" " .. status) or ""))
        return {
            text = title,
            subText = status,
            pid = app:pid(),
        }
    end)

    local callback = function(result)
        if result then
            print("User selected: " .. result.text)
            print("Activating Neovide with PID: " .. result.pid)
            hs.application.applicationForPID(result.pid):activate()
        else
            print("User cancelled selection")
        end
    end

    print("Showing chooser with " .. #items .. " items")
    hs.chooser.new(callback):choices(items):show()
end

-- hs.hotkey.bind({'cmd', 'ctrl'}, '`', cycleNeovideWindows)

function launch_neovide_at(path)
    print("Launching Neovide at path: " .. path)
    os.execute("pushd " .. path .. "; /opt/homebrew/bin/neovide &")
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
        launch_neovide_at(home .. "/.vim")
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
