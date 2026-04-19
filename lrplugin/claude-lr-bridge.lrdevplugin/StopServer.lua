local LrTasks = import "LrTasks"
local LrDialogs = import "LrDialogs"

LrTasks.startAsyncTask(function()
    require "Server"
    Server.stop()
    LrDialogs.message("Claude LR Bridge", "Server stopped.")
end)
