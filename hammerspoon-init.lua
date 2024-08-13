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
