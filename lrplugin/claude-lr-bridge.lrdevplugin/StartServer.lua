local LrTasks = import "LrTasks"
local LrDialogs = import "LrDialogs"

LrTasks.startAsyncTask(function()
    require "Server"
    if Server._running then
        LrDialogs.message("Claude LR Bridge", "Server is already running on port " .. Server.PORT)
    else
        LrDialogs.message("Claude LR Bridge", "Starting server on port " .. Server.PORT .. "...")
        Server.start()
    end
end)
