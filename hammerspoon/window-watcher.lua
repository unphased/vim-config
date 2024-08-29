local pendingCallback = nil -- only ever gonna be set to one item -- a cb pending registering to next created matching window
local pendingWV = nil

local windowAssociations = {} -- windows that on destroying must run associated cb

local function windowWatcherCallback(win, appName, event)
    if event == hs.window.filter.windowCreated then
        print(appName .. " window created")
        if appName == "Terminal" then
            if pendingCallback then
                print("Terminal window created in time, cb registered.")
                table.insert(windowAssociations, { wv = pendingWV, win = win, cb = pendingCallback })
                print('windowAssociations len ' .. #windowAssociations)
            end
        end
    elseif event == hs.window.filter.windowDestroyed then
        print(appName .. " window destroyed")
        local didRemoveATerminalWin = false
        for i, assoc in ipairs(windowAssociations) do
            if assoc.win == win then
                assoc.cb()
                table.remove(windowAssociations, i)
                didRemoveATerminalWin = true
                print('windowAssociations len ' .. #windowAssociations)
            end
        end

        -- clean up terminal app when the last one tracked by us is removed
        if didRemoveATerminalWin --[[ and appName == "Terminal"]] and #windowAssociations == 0 then
            local terminalApp = win:application()
            if terminalApp and 0 == #terminalApp:allWindows() then
                print('A tracked Terminal window was just closed, Terminal app has no more windows: closing Terminal.')
                terminalApp:kill()
            end
        end
    elseif event == hs.window.filter.windowFocused then
        print(appName .. " window focused")
        -- focus the corresponding wv/win!
        for i, assoc in ipairs(windowAssociations) do
            if assoc.win == win then
                assoc.wv:show()
            end
        end
    end
end
local myWindowFilter = hs.window.filter.new():setDefaultFilter({})
myWindowFilter:subscribe( {
    hs.window.filter.windowCreated,
    hs.window.filter.windowDestroyed,
    hs.window.filter.windowFocused,
}, windowWatcherCallback)

local function specifyRelatedWebView(wv, closeCallback)
    pendingCallback = closeCallback
    pendingWV = wv
    print('pendingCallback set')
    hs.timer.doAfter(0.2, function()
        pendingCallback = nil
        pendingWV = nil
        print('pendingCallback now nil')
    end)
end

hs.alert.show("Window watcher loaded")

return {
    specifyRelatedWebView = specifyRelatedWebView
}
