local callbackRegistry = {}

local function windowWatcherCallback(win, appName, event)
    if event == hs.window.filter.windowCreated then
        print(appName .. " window created")
        if appName == "Terminal" and callbackRegistry[win:id()] then
            callbackRegistry[win:id()].created(win)
        end
    elseif event == hs.window.filter.windowDestroyed then
        print(appName .. " window closed")
        if appName == "Terminal" and callbackRegistry[win:id()] then
            callbackRegistry[win:id()].destroyed(win)
            callbackRegistry[win:id()] = nil  -- Remove the callbacks after execution
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

local function registerCallbacks(createdCallback, destroyedCallback)
    local windowId = hs.host.uuid()
    callbackRegistry[windowId] = {
        created = createdCallback,
        destroyed = destroyedCallback
    }
    return windowId
end

local function unregisterCallbacks(windowId)
    callbackRegistry[windowId] = nil
end

hs.alert.show("Window watcher loaded")

return {
    registerCallbacks = registerCallbacks,
    unregisterCallbacks = unregisterCallbacks
}
