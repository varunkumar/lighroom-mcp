local LrTasks = import "LrTasks"
local LrDialogs = import "LrDialogs"

LrTasks.startAsyncTask(function()
    require "Server"
    Server.stop()
    LrDialogs.showBezel("Claude LR Bridge stopped")
end)
