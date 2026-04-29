local LrTasks = import "LrTasks"
local LrDialogs = import "LrDialogs"

LrTasks.startAsyncTask(function()
    require "Server"
    Server.stop()
    LrDialogs.showBezel("LR MCP Bridge stopped")
end)
