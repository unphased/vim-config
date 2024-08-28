-- Toggle Hammerspoon console. records focused window on open, so may return to the wrong window upon using it to close.
local windowHolder
hs.hotkey.bind("Ctrl-Cmd", "H", function()
    local hspoon = hs.application(hs.processInfo.processID)
    local conswin = hspoon:mainWindow()
    if conswin and hspoon:isFrontmost() then
        conswin:close()
        if windowHolder and #windowHolder:role() ~= 0 then
            windowHolder:becomeMain():focus()
        end
        windowHolder = nil
    else
        windowHolder = hs.window.frontmostWindow()
        hs.openConsole()
    end
end)


local home = os.getenv("HOME")

-- watcher object must be assigned to global not to get GC'd
myWatcher = hs.pathwatcher.new(home .. "/.vim/hammerspoon/main-init.lua", function(files)
    -- Use a timer to delay the reload slightly
    hs.timer.doAfter(0.5, function()
        hs.reload()
    end)
end):start()

local status, err = pcall(dofile, home .. "/.vim/hammerspoon/main-init.lua")

if not status then
    print(string.format("init script failed to launch: %s", err))
    hs.alert.show("Hammerspoon FALLBACK config loaded")
end
