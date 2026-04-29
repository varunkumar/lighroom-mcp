local LrTasks = import "LrTasks"
local LrDialogs = import "LrDialogs"

LrTasks.startAsyncTask(function()
    require "Server"
    LrDialogs.showBezel("LR MCP Bridge started")
    Server.start()  -- generation counter evicts any previously running loop
end)
