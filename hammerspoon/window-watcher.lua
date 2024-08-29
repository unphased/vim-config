local terminalWindowCreatedCallback = nil
local terminalWindowDestroyedCallback = nil

local function windowWatcherCallback(win, appName, event)
    if event == hs.window.filter.windowCreated then
        print(appName .. " window created")
        if appName == "Terminal" and terminalWindowCreatedCallback then
            terminalWindowCreatedCallback(win)
        end
    elseif event == hs.window.filter.windowDestroyed then
        print(appName .. " window closed")
        if appName == "Terminal" and terminalWindowDestroyedCallback then
            terminalWindowDestroyedCallback(win)
        end
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

local function setTerminalWindowCreatedCallback(callback)
    terminalWindowCreatedCallback = callback
end

local function setTerminalWindowDestroyedCallback(callback)
    terminalWindowDestroyedCallback = callback
end

hs.alert.show("Window watcher loaded")

return {
    setTerminalWindowCreatedCallback = setTerminalWindowCreatedCallback,
    setTerminalWindowDestroyedCallback = setTerminalWindowDestroyedCallback
}
