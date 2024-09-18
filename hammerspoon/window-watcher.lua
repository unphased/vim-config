local pendingCallback = nil -- only ever gonna be set to one item -- a cb pending registering to next created matching window
local pendingWV = nil

local windowAssociations = {} -- windows that on destroying must run associated cb

local function windowWatcherCallback(win, appName, event)
    if event == hs.window.filter.windowCreated then
        print(appName .. " window created")
        if appName == "iTerm2" then
            if pendingCallback then
                print("Terminal window created in time, cb registered.")
                table.insert(windowAssociations, { wv = pendingWV, win = win, cb = pendingCallback })
                print('windowAssociations len ' .. #windowAssociations)
            else
                print("i saw an iterm window but there is no pendingCallback...")
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
                print('A tracked iTerm window was just closed, iTerm app has no more windows: closing iTerm.')
                terminalApp:kill()
            end
        end
    elseif event == hs.window.filter.windowFocused then
        print(appName .. " window focused")
        -- focus the corresponding wv/win and bring it to the same space!
        for i, assoc in ipairs(windowAssociations) do
            if assoc.win == win then
                local screen = win:screen()
                local frame = win:frame()
                assoc.wv:moveToScreen(screen)
                assoc.wv:setFrame(frame)
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
    print('pendiingCallback set')
    hs.timer.doAfter(1, function()
        pendingCallback = nil
        pendingWV = nil
        print('pendingCallback now nil')
    end)
end

hs.alert.show("Window watcher loaded")

return {
    specifyRelatedWebView = specifyRelatedWebView
}
