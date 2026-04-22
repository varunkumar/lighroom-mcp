local LrTasks = import "LrTasks"

-- Auto-start the bridge server when Lightroom launches
LrTasks.startAsyncTask(function()
    require "Server"
    Server.stop()   -- stop any stale loop from a previous (crashed) load
    LrTasks.sleep(0.1)  -- let old loop exit
    Server.start()
end)
