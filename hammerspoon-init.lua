local home = os.getenv("HOME")
local status, err = pcall(dofile, home .. "/.vim/hammerspoon/main-init.lua")

if not status then
    print(string.format("init script failed to pcall with: %s", err))
    -- watcher object must be assigned to global not to get GC'd
    _G.myWatcher = hs.pathwatcher.new(home .. "/.vim/hammerspoon/main-init.lua", function(files)
      -- Use a timer to delay the reload slightly
      hs.timer.doAfter(0.5, function()
        hs.reload()
      end)
    end):start()
    hs.alert.show("Hammerspoon FALLBACK config loaded")
end
