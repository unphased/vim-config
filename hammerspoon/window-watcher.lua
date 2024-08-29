local pendingCallbacks = {}

local function windowWatcherCallback(win, appName, event)
    if event == hs.window.filter.windowCreated and appName == "Terminal" then
        print("Terminal window created")
        for i, callback in ipairs(pendingCallbacks) do
            callback(win)
            table.remove(pendingCallbacks, i)
        end
    end
end

local myWindowFilter = hs.window.filter.new():setDefaultFilter({})
myWindowFilter:subscribe(hs.window.filter.windowCreated, windowWatcherCallback)

local function queueCallback(callback)
    table.insert(pendingCallbacks, callback)
    hs.timer.doAfter(1, function()
        for i, cb in ipairs(pendingCallbacks) do
            if cb == callback then
                table.remove(pendingCallbacks, i)
                callback(nil)  -- Call the callback with nil if no window was created
                break
            end
        end
    end)
end

hs.alert.show("Window watcher loaded")

return {
    queueCallback = queueCallback
}
