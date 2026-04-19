--[[
  Claude LR Bridge - Server Module
  Runs a TCP socket server inside Lightroom.
  Listens for JSON commands from the MCP server and applies them
  using LrDevelopController.
--]]

local LrSockets    = import "LrSockets"
local LrTasks      = import "LrTasks"
local LrDevelopController = import "LrDevelopController"
local LrApplication = import "LrApplication"
local LrCatalog    = import "LrCatalog"
local LrLogger     = import "LrLogger"
local LrJSON       = import "LrJSON"

local log = LrLogger("ClaudeLRBridge")
log:enable("logfile")

Server = {}
Server._running = false
Server._socket  = nil
Server.PORT = 54321

-- All develop parameters supported by LrDevelopController
local DEVELOP_PARAMS = {
    -- Tone
    "Exposure", "Contrast", "Highlights", "Shadows", "Whites", "Blacks",
    "Brightness", "Recovery", "FillLight",
    -- Presence
    "Clarity", "Dehaze", "Vibrance", "Saturation",
    -- White Balance
    "Temperature", "Tint",
    -- Tone Curve
    "ParametricDarks", "ParametricLights", "ParametricShadows", "ParametricHighlights",
    "ParametricShadowSplit", "ParametricMidtoneSplit", "ParametricHighlightSplit",
    -- HSL
    "HueAdjustmentRed", "HueAdjustmentOrange", "HueAdjustmentYellow",
    "HueAdjustmentGreen", "HueAdjustmentAqua", "HueAdjustmentBlue",
    "HueAdjustmentPurple", "HueAdjustmentMagenta",
    "SaturationAdjustmentRed", "SaturationAdjustmentOrange", "SaturationAdjustmentYellow",
    "SaturationAdjustmentGreen", "SaturationAdjustmentAqua", "SaturationAdjustmentBlue",
    "SaturationAdjustmentPurple", "SaturationAdjustmentMagenta",
    "LuminanceAdjustmentRed", "LuminanceAdjustmentOrange", "LuminanceAdjustmentYellow",
    "LuminanceAdjustmentGreen", "LuminanceAdjustmentAqua", "LuminanceAdjustmentBlue",
    "LuminanceAdjustmentPurple", "LuminanceAdjustmentMagenta",
    -- Detail
    "Sharpness", "SharpenRadius", "SharpenDetail", "SharpenEdgeMasking",
    "LuminanceSmoothing", "LuminanceNoiseReductionDetail",
    "ColorNoiseReduction", "ColorNoiseReductionDetail", "ColorNoiseReductionSmoothness",
    -- Lens
    "LensProfileEnable", "AutoLateralCA",
    "VignetteAmount", "VignetteMidpoint",
    -- Transform
    "PerspectiveVertical", "PerspectiveHorizontal",
    "PerspectiveRotate", "PerspectiveScale",
    -- Effects
    "PostCropVignetteAmount", "PostCropVignetteMidpoint",
    "PostCropVignetteFeather", "PostCropVignetteRoundness",
    "GrainAmount", "GrainSize", "GrainFrequency",
}

local function buildParamIndex()
    local idx = {}
    for _, p in ipairs(DEVELOP_PARAMS) do
        idx[p:lower()] = p
    end
    return idx
end
local PARAM_INDEX = buildParamIndex()

local function getCurrentPhoto()
    local catalog = LrApplication.activeCatalog()
    local photo = catalog:getTargetPhoto()
    return photo
end

local function applyDevelopSettings(settings)
    local catalog = LrApplication.activeCatalog()
    local photo = getCurrentPhoto()
    if not photo then
        return false, "No photo selected in Lightroom"
    end

    -- Switch to Develop module
    local app = LrApplication.activeCatalog()
    LrDevelopController.revealPanelForParameter("Exposure")

    local applied = {}
    local skipped = {}

    catalog:withWriteAccessDo("Claude Edit", function()
        for key, value in pairs(settings) do
            -- Normalise key: try exact match first, then lowercase lookup
            local paramName = PARAM_INDEX[key:lower()] or key
            local ok, err = pcall(function()
                LrDevelopController.setValue(paramName, tonumber(value) or value)
            end)
            if ok then
                table.insert(applied, paramName .. "=" .. tostring(value))
            else
                table.insert(skipped, paramName .. "(" .. tostring(err) .. ")")
            end
        end
    end)

    local msg = "Applied: " .. table.concat(applied, ", ")
    if #skipped > 0 then
        msg = msg .. " | Skipped: " .. table.concat(skipped, ", ")
    end
    return true, msg
end

local function getCurrentSettings()
    local photo = getCurrentPhoto()
    if not photo then
        return nil, "No photo selected"
    end

    local settings = {}
    for _, param in ipairs(DEVELOP_PARAMS) do
        local ok, val = pcall(function()
            return LrDevelopController.getValue(param)
        end)
        if ok and val ~= nil then
            settings[param] = val
        end
    end

    -- Also grab filename and basic metadata
    local info = {
        filename = photo:getFormattedMetadata("fileName"),
        rating   = photo:getRawMetadata("rating"),
        settings = settings,
    }
    return info, nil
end

local function applyAutoTone()
    local catalog = LrApplication.activeCatalog()
    local photo = getCurrentPhoto()
    if not photo then return false, "No photo selected" end
    catalog:withWriteAccessDo("Claude AutoTone", function()
        LrDevelopController.autoTone()
    end)
    return true, "Auto tone applied"
end

local function resetAllSettings()
    local catalog = LrApplication.activeCatalog()
    local photo = getCurrentPhoto()
    if not photo then return false, "No photo selected" end
    catalog:withWriteAccessDo("Claude Reset", function()
        LrDevelopController.resetAllDevelopAdjustments()
    end)
    return true, "All develop settings reset"
end

local function handleRequest(data)
    local ok, req = pcall(LrJSON.decode, data)
    if not ok or type(req) ~= "table" then
        return LrJSON.encode({ success = false, error = "Invalid JSON: " .. tostring(data) })
    end

    local cmd = req.command
    local response = {}

    if cmd == "ping" then
        response = { success = true, message = "Claude LR Bridge running" }

    elseif cmd == "apply_settings" then
        local s, msg = applyDevelopSettings(req.settings or {})
        response = { success = s, message = msg }

    elseif cmd == "get_settings" then
        local info, err = getCurrentSettings()
        if info then
            response = { success = true, data = info }
        else
            response = { success = false, error = err }
        end

    elseif cmd == "auto_tone" then
        local s, msg = applyAutoTone()
        response = { success = s, message = msg }

    elseif cmd == "reset" then
        local s, msg = resetAllSettings()
        response = { success = s, message = msg }

    else
        response = { success = false, error = "Unknown command: " .. tostring(cmd) }
    end

    return LrJSON.encode(response)
end

function Server.start()
    if Server._running then
        log:info("Server already running")
        return
    end

    local server, err = LrSockets.bind("localhost", Server.PORT)
    if not server then
        log:error("Failed to bind socket: " .. tostring(err))
        return
    end

    Server._socket  = server
    Server._running = true
    log:info("Claude LR Bridge listening on port " .. Server.PORT)

    while Server._running do
        local client, cerr = server:accept(1.0)  -- 1 second timeout
        if client then
            LrTasks.startAsyncTask(function()
                -- Read until newline delimiter
                local buf = ""
                while true do
                    local chunk, rerr = client:receive(1024)
                    if rerr then break end
                    if chunk then
                        buf = buf .. chunk
                        if buf:find("\n") then break end
                    end
                end
                buf = buf:gsub("\n", "")
                if #buf > 0 then
                    local responseStr = handleRequest(buf)
                    client:send(responseStr .. "\n")
                end
                client:close()
            end)
        end
        LrTasks.yield()
    end

    server:close()
    log:info("Claude LR Bridge stopped")
end

function Server.stop()
    Server._running = false
    if Server._socket then
        Server._socket:close()
        Server._socket = nil
    end
end

return Server
