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

-- ── Base64 encoder ──────────────────────────────────────────────────────────
local _b64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

local function base64Encode(data)
    local result = {}
    local bytes  = { data:byte(1, #data) }
    local padding = (3 - #bytes % 3) % 3
    for _ = 1, padding do bytes[#bytes + 1] = 0 end

    for i = 1, #bytes, 3 do
        local b1, b2, b3 = bytes[i], bytes[i + 1], bytes[i + 2]
        local n = b1 * 65536 + b2 * 256 + b3
        result[#result + 1] = _b64:sub(math.floor(n / 262144) % 64 + 1, math.floor(n / 262144) % 64 + 1)
        result[#result + 1] = _b64:sub(math.floor(n /   4096) % 64 + 1, math.floor(n /   4096) % 64 + 1)
        result[#result + 1] = _b64:sub(math.floor(n /     64) % 64 + 1, math.floor(n /     64) % 64 + 1)
        result[#result + 1] = _b64:sub(              n        % 64 + 1,               n        % 64 + 1)
    end

    local encoded = table.concat(result)
    return encoded:sub(1, #encoded - padding) .. string.rep("=", padding)
end

-- ── Length-prefix framing helpers ───────────────────────────────────────────

local function recvMessage(client)
    -- Read 4-byte big-endian uint32 header
    local hdr = ""
    while #hdr < 4 do
        local chunk, err = client:receive(4 - #hdr)
        if err then return nil, "recv header: " .. tostring(err) end
        hdr = hdr .. chunk
    end
    local b1, b2, b3, b4 = hdr:byte(1, 4)
    local msgLen = b1 * 16777216 + b2 * 65536 + b3 * 256 + b4

    -- Read exact payload
    local buf = ""
    while #buf < msgLen do
        local chunk, err = client:receive(math.min(4096, msgLen - #buf))
        if err then return nil, "recv body: " .. tostring(err) end
        buf = buf .. chunk
    end
    return buf, nil
end

local function sendMessage(client, payload)
    local len = #payload
    local hdr = string.char(
        math.floor(len / 16777216) % 256,
        math.floor(len /    65536) % 256,
        math.floor(len /      256) % 256,
        len % 256
    )
    client:send(hdr .. payload)
end

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

local function exportPreview(size)
    local photo = getCurrentPhoto()
    if not photo then return nil, "No photo selected" end

    local thumbSize = math.min(tonumber(size) or 1500, 2048)
    local jpegData  = nil
    local done      = false

    -- requestJpegThumbnail is callback-based; poll until the callback fires
    photo:requestJpegThumbnail(thumbSize, thumbSize, function(jpeg, _reason)
        jpegData = jpeg
        done     = true
    end)

    local elapsed = 0
    while not done and elapsed < 5.0 do
        LrTasks.sleep(0.05)
        elapsed = elapsed + 0.05
    end

    if not jpegData then
        return nil, "Thumbnail timed out or unavailable"
    end

    return base64Encode(jpegData), nil
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

    elseif cmd == "export_preview" then
        local b64, err = exportPreview(req.size)
        if b64 then
            response = { success = true, data = b64 }
        else
            response = { success = false, error = err }
        end

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
                local data, err = recvMessage(client)
                if data and #data > 0 then
                    local responseStr = handleRequest(data)
                    sendMessage(client, responseStr)
                elseif err then
                    log:error("Read error: " .. err)
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
