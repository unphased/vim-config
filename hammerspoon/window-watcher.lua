local function windowWatcherCallback(win, appName, event)
    if event == hs.window.filter.windowCreated then
        hs.alert.show(appName .. " window created")
        -- Example: Automatically move new Chrome windows to a specific position
        -- if appName == "Google Chrome" then
        --     win:moveToScreen(hs.screen.primaryScreen())
        -- end
    elseif event == hs.window.filter.windowDestroyed then
        hs.alert.show(appName .. " window closed")
    elseif event == hs.window.filter.windowFocused then
        hs.alert.show(appName .. " window focused")
    end
end

local myWindowFilter = hs.window.filter.new():setDefaultFilter({})
myWindowFilter:subscribe({
    hs.window.filter.windowCreated,
    hs.window.filter.windowDestroyed,
    hs.window.filter.windowFocused,
}, windowWatcherCallback)

hs.alert.show("Window watcher loaded")
