--[[
  Claude LR Bridge - Server Module
  Uses file-based IPC to communicate with the Python MCP server.
  Python writes /tmp/lr_mcp_req.json; Lua polls, processes, writes /tmp/lr_mcp_res.json.
--]]

local LrTasks             = import "LrTasks"
local LrFileUtils         = import "LrFileUtils"
local LrDevelopController = import "LrDevelopController"
local LrApplication       = import "LrApplication"
local LrLogger            = import "LrLogger"

local REQ_FILE  = "/tmp/lr_mcp_req.json"
local RES_FILE  = "/tmp/lr_mcp_res.json"
local POLL_INTERVAL = 0.05  -- seconds

-- ── Bundled JSON encoder/decoder (no LrJSON dependency) ─────────────────────
local function jsonEncodeValue(val)
    local t = type(val)
    if t == "nil" then
        return "null"
    elseif t == "boolean" then
        return val and "true" or "false"
    elseif t == "number" then
        if val ~= val then return "null" end
        return tostring(val)
    elseif t == "string" then
        return '"' .. val:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n'):gsub('\r', '\\r'):gsub('\t', '\\t') .. '"'
    elseif t == "table" then
        local isArray = true
        local maxN = 0
        for k, _ in pairs(val) do
            if type(k) ~= "number" or k ~= math.floor(k) or k < 1 then
                isArray = false; break
            end
            if k > maxN then maxN = k end
        end
        if isArray and maxN == #val then
            local items = {}
            for _, v in ipairs(val) do items[#items+1] = jsonEncodeValue(v) end
            return "[" .. table.concat(items, ",") .. "]"
        else
            local items = {}
            for k, v in pairs(val) do
                items[#items+1] = '"' .. tostring(k) .. '":' .. jsonEncodeValue(v)
            end
            return "{" .. table.concat(items, ",") .. "}"
        end
    end
    return "null"
end

local function jsonEncode(val)
    return jsonEncodeValue(val)
end

local jsonDecodeValue  -- forward declaration

local function jsonSkipWS(s, i)
    while i <= #s and s:sub(i,i):match("%s") do i = i + 1 end
    return i
end

local function jsonDecodeString(s, i)
    i = i + 1
    local res = {}
    while i <= #s do
        local c = s:sub(i, i)
        if c == '"' then return table.concat(res), i + 1
        elseif c == '\\' then
            local e = s:sub(i+1, i+1)
            local map = { ['"']='"', ['\\']='\\', n='\n', r='\r', t='\t', ['/']='/' }
            res[#res+1] = map[e] or e
            i = i + 2
        else res[#res+1] = c; i = i + 1 end
    end
    error("Unterminated string")
end

local function jsonDecodeArray(s, i)
    i = i + 1
    local arr = {}
    i = jsonSkipWS(s, i)
    if s:sub(i,i) == ']' then return arr, i + 1 end
    while true do
        local v; v, i = jsonDecodeValue(s, i)
        arr[#arr+1] = v
        i = jsonSkipWS(s, i)
        local c = s:sub(i,i)
        if c == ']' then return arr, i + 1 end
        i = i + 1; i = jsonSkipWS(s, i)
    end
end

local function jsonDecodeObject(s, i)
    i = i + 1
    local obj = {}
    i = jsonSkipWS(s, i)
    if s:sub(i,i) == '}' then return obj, i + 1 end
    while true do
        i = jsonSkipWS(s, i)
        local k; k, i = jsonDecodeString(s, i)
        i = jsonSkipWS(s, i); i = i + 1; i = jsonSkipWS(s, i)
        local v; v, i = jsonDecodeValue(s, i)
        obj[k] = v
        i = jsonSkipWS(s, i)
        local c = s:sub(i,i)
        if c == '}' then return obj, i + 1 end
        i = i + 1
    end
end

jsonDecodeValue = function(s, i)
    i = jsonSkipWS(s, i)
    local c = s:sub(i,i)
    if     c == '"' then return jsonDecodeString(s, i)
    elseif c == '{' then return jsonDecodeObject(s, i)
    elseif c == '[' then return jsonDecodeArray(s, i)
    elseif c == 't' then return true,  i + 4
    elseif c == 'f' then return false, i + 5
    elseif c == 'n' then return nil,   i + 4
    else
        local num = s:match("^-?%d+%.?%d*[eE]?[+-]?%d*", i)
        if num then return tonumber(num), i + #num end
        error("Unexpected character: " .. c)
    end
end

local function jsonDecode(s)
    local val, _ = jsonDecodeValue(s, 1)
    return val
end

-- ── Base64 encoder ──────────────────────────────────────────────────────────
local _b64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

local function base64Encode(data)
    local result  = {}
    local len     = #data
    local padding = (3 - len % 3) % 3
    -- Process 3 bytes at a time without unpacking the whole string onto the stack
    for i = 1, len, 3 do
        local b1 = data:byte(i)     or 0
        local b2 = data:byte(i + 1) or 0
        local b3 = data:byte(i + 2) or 0
        local n  = b1 * 65536 + b2 * 256 + b3
        result[#result + 1] = _b64:sub(math.floor(n / 262144) % 64 + 1, math.floor(n / 262144) % 64 + 1)
        result[#result + 1] = _b64:sub(math.floor(n /   4096) % 64 + 1, math.floor(n /   4096) % 64 + 1)
        result[#result + 1] = _b64:sub(math.floor(n /     64) % 64 + 1, math.floor(n /     64) % 64 + 1)
        result[#result + 1] = _b64:sub(              n        % 64 + 1,               n        % 64 + 1)
    end
    local encoded = table.concat(result)
    -- Replace trailing padding chars
    if padding == 1 then
        return encoded:sub(1, #encoded - 1) .. "="
    elseif padding == 2 then
        return encoded:sub(1, #encoded - 2) .. "=="
    end
    return encoded
end

local log = LrLogger("ClaudeLRBridge")
log:enable("logfile")

Server = {}
Server._running = false

-- All develop parameters supported by LrDevelopController
local DEVELOP_PARAMS = {
    -- Tone
    "Exposure", "Contrast", "Highlights", "Shadows", "Whites", "Blacks",
    "Brightness", "Recovery", "FillLight",
    -- Presence
    "Clarity", "Texture", "Dehaze", "Vibrance", "Saturation",
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
    "PerspectiveAspect", "PerspectiveX", "PerspectiveY", "PerspectiveUpright",
    -- Crop
    "CropAngle", "CropTop", "CropBottom", "CropLeft", "CropRight",
    -- Effects
    "PostCropVignetteAmount", "PostCropVignetteMidpoint",
    "PostCropVignetteFeather", "PostCropVignetteRoundness",
    "GrainAmount", "GrainSize", "GrainFrequency",
    -- Color Grading (3-way color wheels)
    "ColorGradeBlending",
    "ColorGradeGlobalHue", "ColorGradeGlobalLum", "ColorGradeGlobalSat",
    "ColorGradeHighlightLum",
    "ColorGradeMidtoneHue", "ColorGradeMidtoneLum", "ColorGradeMidtoneSat",
    "ColorGradeShadowLum",
    -- B&W Mix
    "GrayMixerRed", "GrayMixerOrange", "GrayMixerYellow", "GrayMixerGreen",
    "GrayMixerAqua", "GrayMixerBlue", "GrayMixerPurple", "GrayMixerMagenta",
    -- Split Toning (legacy but still functional)
    "SplitToningBalance",
    "SplitToningHighlightHue", "SplitToningHighlightSaturation",
    "SplitToningShadowHue", "SplitToningShadowSaturation",
    -- Defringe
    "DefringeGreenAmount", "DefringeGreenHueHi", "DefringeGreenHueLo",
    "DefringePurpleAmount", "DefringePurpleHueHi", "DefringePurpleHueLo",
    -- Lens Blur (AI depth-of-field)
    "LensBlurActive", "LensBlurAmount", "LensBlurCatEye",
    "LensBlurFocalRange", "LensBlurHighlightsBoost",
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

local function batchApplySettings(settings)
    local catalog = LrApplication.activeCatalog()
    local photos  = catalog:getTargetPhotos()   -- all selected photos

    if not photos or #photos == 0 then
        return false, "No photos selected"
    end

    local count   = 0
    local skipped = 0

    for _, photo in ipairs(photos) do
        catalog:withWriteAccessDo("Claude Batch Edit", function()
            local devSettings = {}
            for key, value in pairs(settings) do
                local paramName = PARAM_INDEX[key:lower()] or key
                devSettings[paramName] = tonumber(value) or value
            end
            local ok, err = pcall(function()
                photo:applyDevelopSettings(devSettings)
            end)
            if ok then
                count = count + 1
            else
                skipped = skipped + 1
                log:error("Batch apply failed for photo: " .. tostring(err))
            end
        end)
    end

    return true, string.format("Applied to %d photos, %d skipped", count, skipped)
end

local function cropPhoto(params)
    local catalog = LrApplication.activeCatalog()
    local photo = getCurrentPhoto()
    if not photo then return false, "No photo selected" end

    local applied = {}
    catalog:withWriteAccessDo("Claude Crop", function()
        -- Straighten/rotate angle
        if params.angle ~= nil then
            local ok, err = pcall(function()
                LrDevelopController.straightenAngle(tonumber(params.angle))
            end)
            if not ok then
                -- fall back to setValue
                pcall(function() LrDevelopController.setValue("CropAngle", tonumber(params.angle)) end)
            end
            table.insert(applied, "angle=" .. tostring(params.angle))
        end
        -- Crop bounds (0.0–1.0 normalized)
        for _, k in ipairs({ "CropTop", "CropBottom", "CropLeft", "CropRight" }) do
            local v = params[k] or params[k:lower():sub(5)]  -- accept "top","bottom" etc.
            if v ~= nil then
                pcall(function() LrDevelopController.setValue(k, tonumber(v)) end)
                table.insert(applied, k .. "=" .. tostring(v))
            end
        end
    end)

    if #applied == 0 then
        return false, "No crop parameters provided"
    end
    return true, "Crop applied: " .. table.concat(applied, ", ")
end

-- Valid mask types supported by LrDevelopController.createNewMask
local MASK_TYPES = {
    subject=true, sky=true, background=true,
    person=true, objects=true,
    gradient=true, radialGradient=true,
    brush=true, luminance=true, colorRange=true,
}

local function addMask(maskType, maskParams)
    if not MASK_TYPES[maskType] then
        local valid = {}
        for k in pairs(MASK_TYPES) do valid[#valid+1] = k end
        table.sort(valid)
        return false, "Unknown mask type '" .. tostring(maskType) ..
            "'. Valid types: " .. table.concat(valid, ", ")
    end

    local args = { maskType = maskType }
    -- Pass through any extra params (e.g. angle, midpoint, feather for gradients)
    if type(maskParams) == "table" then
        for k, v in pairs(maskParams) do
            if k ~= "maskType" then args[k] = v end
        end
    end

    local ok, err = pcall(function()
        LrDevelopController.createNewMask(args)
    end)
    if not ok then
        return false, "Failed to create mask: " .. tostring(err)
    end
    return true, "Mask created: " .. maskType
end

-- Valid bokeh shapes for Lens Blur
local BOKEH_TYPES = {
    Circle=true, SoapBubble=true, Blade=true, Ring=true, Anamorphic=true,
}

local function lensBlur(params)
    local catalog = LrApplication.activeCatalog()
    local photo = getCurrentPhoto()
    if not photo then return false, "No photo selected" end

    local applied = {}

    catalog:withWriteAccessDo("Claude Lens Blur", function()
        -- Activate / deactivate
        if params.active ~= nil then
            local v = params.active and 1 or 0
            pcall(function() LrDevelopController.setValue("LensBlurActive", v) end)
            table.insert(applied, "active=" .. tostring(params.active))
        end
        -- Amount
        if params.amount ~= nil then
            pcall(function() LrDevelopController.setValue("LensBlurAmount", tonumber(params.amount)) end)
            table.insert(applied, "amount=" .. tostring(params.amount))
        end
        -- Cat-eye
        if params.catEye ~= nil then
            pcall(function() LrDevelopController.setValue("LensBlurCatEye", tonumber(params.catEye)) end)
            table.insert(applied, "catEye=" .. tostring(params.catEye))
        end
        -- Highlights boost
        if params.highlightsBoost ~= nil then
            pcall(function() LrDevelopController.setValue("LensBlurHighlightsBoost", tonumber(params.highlightsBoost)) end)
            table.insert(applied, "highlightsBoost=" .. tostring(params.highlightsBoost))
        end
    end)

    -- Bokeh shape (outside write access — it's a UI/render property)
    if params.bokeh ~= nil then
        local bokehName = tostring(params.bokeh)
        -- Capitalise first letter to match enum (circle → Circle)
        bokehName = bokehName:sub(1,1):upper() .. bokehName:sub(2)
        if BOKEH_TYPES[bokehName] then
            local ok2, err2 = pcall(function()
                LrDevelopController.setLensBlurBokeh(bokehName)
            end)
            if ok2 then
                table.insert(applied, "bokeh=" .. bokehName)
            else
                table.insert(applied, "bokeh_error=" .. tostring(err2))
            end
        else
            table.insert(applied, "bokeh_skipped(invalid)=" .. bokehName)
        end
    end

    -- Set focal range from subject (AI depth map)
    if params.focalRangeFromSubject then
        local ok2, err2 = pcall(function()
            LrDevelopController.setLensBlurFocalRangeFromSubject()
        end)
        if ok2 then
            table.insert(applied, "focalRangeFromSubject=true")
        else
            table.insert(applied, "focalRangeFromSubject_error=" .. tostring(err2))
        end
    end

    if #applied == 0 then
        return false, "No lens blur parameters provided"
    end
    return true, "Lens blur applied: " .. table.concat(applied, ", ")
end

local function enhancePhoto(params)
    local catalog = LrApplication.activeCatalog()
    local photo = getCurrentPhoto()
    if not photo then return false, "No photo selected" end

    -- Build the enhance options table
    local opts = {}
    if params.denoise ~= nil then
        opts.denoise = params.denoise and true or false
    end
    if params.denoiseAmount ~= nil then
        opts.denoiseAmount = tonumber(params.denoiseAmount)
    end
    if params.superRes ~= nil then
        opts.superRes = params.superRes and true or false
    end
    if params.rawDetails ~= nil then
        opts.rawDetails = params.rawDetails and true or false
    end

    if next(opts) == nil then
        return false, "No enhance options provided. Use: denoise, denoiseAmount (0-100), superRes, rawDetails"
    end

    local ok2, err2 = pcall(function()
        catalog:withWriteAccessDo("Claude Enhance", function()
            LrDevelopController.setEnhance(opts)
        end)
    end)
    if not ok2 then
        return false, "Enhance failed: " .. tostring(err2)
    end

    local parts = {}
    for k, v in pairs(opts) do
        parts[#parts+1] = k .. "=" .. tostring(v)
    end
    return true, "Enhance triggered: " .. table.concat(parts, ", ") ..
        ". Note: AI Denoise/Super Resolution may take time to complete in the background."
end

local function handleRequest(data)
    local ok, req = pcall(jsonDecode, data)
    if not ok or type(req) ~= "table" then
        return jsonEncode({ success = false, error = "Invalid JSON: " .. tostring(data) })
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

    elseif cmd == "batch_apply_settings" then
        local ok, msg = batchApplySettings(req.settings or {})
        response = { success = ok, message = msg }

    elseif cmd == "crop" then
        local s, msg = cropPhoto(req.params or {})
        response = { success = s, message = msg }

    elseif cmd == "add_mask" then
        local s, msg = addMask(req.maskType, req.params)
        response = { success = s, message = msg }

    elseif cmd == "lens_blur" then
        local s, msg = lensBlur(req.params or {})
        response = { success = s, message = msg }

    elseif cmd == "enhance" then
        local s, msg = enhancePhoto(req.params or {})
        response = { success = s, message = msg }

    else
        response = { success = false, error = "Unknown command: " .. tostring(cmd) }
    end

return jsonEncode(response)
end

function Server.start()
    if Server._running then
        log:info("Server already running")
        return
    end

    Server._running = true
    -- Clean up any stale files from a previous run
    LrFileUtils.delete(REQ_FILE)
    LrFileUtils.delete(RES_FILE)
    log:info("Claude LR Bridge started (file IPC mode)")

    while Server._running do
        local f = io.open(REQ_FILE, "r")
        if f then
            local data = f:read("*a")
            f:close()
            LrFileUtils.delete(REQ_FILE)

            if data and #data > 0 then
                local responseStr = handleRequest(data)
                local rf = io.open(RES_FILE, "w")
                if rf then
                    rf:write(responseStr)
                    rf:close()
                end
            end
        end
        LrTasks.sleep(POLL_INTERVAL)
    end

    log:info("Claude LR Bridge stopped")
end

function Server.stop()
    Server._running = false
end

return Server
