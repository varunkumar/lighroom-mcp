local LrTasks = import "LrTasks"

-- Auto-start the bridge server when Lightroom launches
LrTasks.startAsyncTask(function()
    require "Server"
    Server.start()  -- generation counter evicts any previously running loop
end)
