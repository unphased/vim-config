local function windowWatcherCallback(win, appName, event)
    if event == hs.window.filter.windowCreated then
        print(appName .. " window created")
        -- Example: Automatically move new Chrome windows to a specific position
        -- if appName == "Google Chrome" then
        --     win:moveToScreen(hs.screen.primaryScreen())
        -- end
    elseif event == hs.window.filter.windowDestroyed then
        print(appName .. " window closed")
    elseif event == hs.window.filter.windowFocused then
        print(appName .. " window focused")
    end
end

local myWindowFilter = hs.window.filter.new():setDefaultFilter({})
myWindowFilter:subscribe({
    hs.window.filter.windowCreated,
    hs.window.filter.windowDestroyed,
    hs.window.filter.windowFocused,
}, windowWatcherCallback)

hs.alert.show("Window watcher loaded")
