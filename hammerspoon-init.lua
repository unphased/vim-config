hs.alert.show("Hammerspoon config reloaded")

hs.ipc.cliInstall()
hs.loadSpoon("EmmyLua")

myWatcher = hs.pathwatcher.new(os.getenv("HOME") .. "/.vim/hammerspoon-init.lua/", function(files) hs.reload() end):start()

hs.hotkey.bind({"alt"}, "space", function()
    local app = hs.application.get("neovide")
    if app then
        if not app:mainWindow() then
            print('never happens (neovide no main window)')
            -- app:selectMenuItem({"kitty", "New OS window"})
        elseif app:isFrontmost() then
            app:hide()
        else
            app:activate()
        end
    else
        hs.execute("bash -c 'open -a Terminal'")
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
