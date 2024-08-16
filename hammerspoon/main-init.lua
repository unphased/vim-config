-- hs.ipc.cliInstall()
hs.loadSpoon("EmmyLua")

function cycleNeovideWindows()
    local current = hs.window.focusedWindow()

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

        return {
            text = title,
            subText = status,
            pid = app:pid(),
        }
    end)

    local callback = function(result)
        hs.application.applicationForPID(result.pid):activate()
    end

    hs.chooser.new(callback):choices(items):show()
end

-- hs.hotkey.bind({'cmd', 'ctrl'}, '`', cycleNeovideWindows)

hs.hotkey.bind({"alt"}, "space", function()
    local nv = hs.application.get("com.neovide.neovide")
    if nv then
        print("Type of nv:", type(nv))
        print("nv is", nv)
        if nv:isFrontmost() then
            nv:hide()
        else
            nv:activate()
        end
    else
        os.execute("pushd /Users/slu/.vim; /opt/homebrew/bin/neovide &")
    end
end)


local function getMarkdownFiles(directory)
    local files = hs.fs.dir(directory)
    local markdownFiles = {}
    for file in files do
        if file:match("%.md$") then
            table.insert(markdownFiles, file)
        end
    end
    return markdownFiles
end

local function createButtonsFromFiles(files)
    local buttons = {}
    for i, file in ipairs(files) do
        local button = {
            title = file:gsub("%.md$", ""),
            fn = function()
                hs.execute(string.format('open "%s/util/prompts/%s"', os.getenv("HOME"), file))
            end
        }
        table.insert(buttons, button)
    end
    return buttons
end


hs.hotkey.bind({"cmd", "shift", "alt"}, "X", function()
    hs.execute('bash -c "/usr/sbin/screencapture -i /tmp/screencap.png"')

    local image = hs.image.imageFromPath("/tmp/screencap.png")
    if image then
        local imageView = hs.webview.newBrowser({x = 100, y = 100, w = 640, h = 480})
        imageView:url("file:///tmp/screencap.png")
        imageView:show()

        local promptsDir = os.getenv("HOME") .. "/util/prompts"
        local markdownFiles = getMarkdownFiles(promptsDir)
        local buttons = createButtonsFromFiles(markdownFiles)

        local chooser = hs.chooser.new(function(choice)
            if choice then
                choice.fn()
            end
            imageView:delete()
        end)

        chooser:choices(buttons)
        chooser:show()
    else
        hs.alert.show("Failed to capture screenshot")
    end
end)

hs.alert.show("Hammerspoon config loaded")
