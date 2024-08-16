
-- watcher object must be assigned to global not to get GC'd
myWatcher = hs.pathwatcher.new(os.getenv("HOME") .. "/.vim/hammerspoon-init.lua/", function(files)
    -- Use a timer to delay the reload slightly
    hs.timer.doAfter(0.5, function()
        hs.reload()
    end)
end):start()

hs.alert.show("Hammerspoon FALLBACK config loaded")
