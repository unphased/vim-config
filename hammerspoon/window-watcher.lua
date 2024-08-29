local pendingCallback = nil -- only ever gonna be set to one item -- a cb pending registering to next created matching window

--- @type { win: hs.window, cb: function }[]
local windowAssociations = {} -- windows that on destroying must run associated cb

local function windowWatcherCallback(win, appName, event)
    if event == hs.window.filter.windowCreated then
        print(appName .. " window created")
        if appName == "Terminal" then
            if pendingCallback then
                print("Terminal window created in time, cb registered.")
                table.insert(windowAssociations, { win = win, cb = pendingCallback })
                print('windowAssociations len ' .. #windowAssociations)
            end
        end
    elseif event == hs.window.filter.windowDestroyed then
        print(appName .. " window destroyed")
        for i, assoc in ipairs(windowAssociations) do
            if assoc.win == win then
                assoc.cb()
                table.remove(windowAssociations, i)
                print('windowAssociations len ' .. #windowAssociations)
            end
        end
        print('(end of destroyed loop) windowAssociations len ' .. #windowAssociations)
    elseif event == hs.window.filter.windowFocused then
        print(appName .. " window focused")
    end
end
local myWindowFilter = hs.window.filter.new():setDefaultFilter({})
myWindowFilter:subscribe( {
    hs.window.filter.windowCreated,
    hs.window.filter.windowDestroyed,
    hs.window.filter.windowFocused,
}, windowWatcherCallback)

local function queueSelfRemovingCallback(callback)
    pendingCallback = callback
    print('pendingCallback now set')
    hs.timer.doAfter(0.2, function()
        pendingCallback = nil
        print('pendingCallback now nil')
    end)
end

hs.alert.show("Window watcher loaded")

return {
    queueSRCB = queueSelfRemovingCallback
}
