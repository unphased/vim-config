local home = os.getenv("HOME")
local status, err = pcall(dofile, home .. "/.vim/hammerspoon/main-init.lua")

if not status then
    print(string.format("testing init file failed with: %s", err))
    print("Loading fallback...")
    dofile(home .. "/.vim/hammerspoon/fallback-init.lua")
end
