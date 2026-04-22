local LrTasks = import "LrTasks"
local LrDialogs = import "LrDialogs"

LrTasks.startAsyncTask(function()
    require "Server"
    Server.stop()   -- stop any stale loop from a previous (crashed) load
    LrTasks.sleep(0.1)  -- let old loop exit
    LrDialogs.message("Claude LR Bridge", "Starting Claude LR Bridge (file IPC)...")
    Server.start()
end)
