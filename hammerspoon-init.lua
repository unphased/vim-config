hs.hotkey.bind({"alt"}, "space", function()
    local app = hs.application.get("neovide")
    if app then
        if not app:mainWindow() then
            -- app:selectMenuItem({"kitty", "New OS window"})
        elseif app:isFrontmost() then
            app:hide()
        else
            app:activate()
        end
    else
        hs.application.launchOrFocus("neovide")
    end
end)

hs.hotkey.bind({"cmd", "shift", "alt"}, "X", function()
    hs.execute('bash -c "/usr/sbin/screencapture -i /tmp/screencap.png"')
    hs.execute('open "/Users/slu/.vim/AI screen help.terminal"')
end)
