--[[
  Lightroom MCP Bridge - Server Module
  Uses file-based IPC to communicate with the Python MCP server.
  Python writes /tmp/lr_mcp_req.json; Lua polls, processes, writes /tmp/lr_mcp_res.json.
--]]

local LrTasks             = import "LrTasks"
local LrFileUtils         = import "LrFileUtils"
local LrDevelopController = import "LrDevelopController"
local LrApplication       = import "LrApplication"
local LrLogger            = import "LrLogger"

local REQ_FILE      = "/tmp/lr_mcp_req.json"
local RES_FILE      = "/tmp/lr_mcp_res.json"
local POLL_INTERVAL = 0.05  -- seconds
local VERSION       = "1.0.3"  -- keep in sync with Info.lua VERSION

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

local log = LrLogger("LrMCPBridge")
log:enable("logfile")

Server = {}
Server._running = false
-- _clrb_gen is a persistent global (not inside Server{}) so it survives
-- each re-execution of this file via require "Server". This ensures the
-- generation counter actually evicts old polling tasks even when require
-- creates a fresh Server table.
_clrb_gen = (_clrb_gen or 0)

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

-- Local adjustment parameters settable on a mask via LrDevelopController.setValue("local_*")
local LOCAL_PARAMS = {
    "Exposure", "Contrast", "Highlights", "Shadows", "Whites", "Blacks",
    "Clarity", "Texture", "Dehaze", "Vibrance", "Saturation",
    "Temperature", "Tint",
    "Sharpness", "LuminanceNoise", "ColorNoise", "MoireFilter", "Defringe",
    "ToningHue", "ToningSaturation",
}

local LOCAL_PARAM_INDEX = (function()
    local idx = {}
    for _, p in ipairs(LOCAL_PARAMS) do idx[p:lower()] = "local_" .. p end
    return idx
end)()

local function getCurrentPhoto()
    local catalog = LrApplication.activeCatalog()
    local photo = catalog:getTargetPhoto()
    return photo
end

local function applyDevelopSettings(settings)
    local photo = getCurrentPhoto()
    if not photo then
        return false, "No photo selected in Lightroom"
    end

    local applied = {}
    local skipped = {}
    local catalog = LrApplication.activeCatalog()

    -- Run setValue + catalog flush in a fresh LrTask so the call stack is clean
    -- (no pending C function references that would block withWriteAccessDo yield).
    local done = false
    LrTasks.startAsyncTask(function()
        for key, value in pairs(settings) do
            local paramName = PARAM_INDEX[key:lower()] or key
            local ok2, err2 = pcall(function()
                LrDevelopController.setValue(paramName, tonumber(value) or value)
            end)
            if ok2 then
                table.insert(applied, paramName .. "=" .. tostring(value))
                log:info("setValue " .. paramName .. "=" .. tostring(value))
            else
                table.insert(skipped, paramName .. "(" .. tostring(err2) .. ")")
                log:error("setValue failed " .. paramName .. ": " .. tostring(err2))
            end
        end
        -- Flush buffered Local* changes to the catalog.
        catalog:withWriteAccessDo("Flush Settings", function() end, {timeout = 30})
        done = true
    end)

    -- Wait for the async task (cooperative yield via sleep).
    local elapsed = 0
    while not done and elapsed < 10 do
        LrTasks.sleep(0.05)
        elapsed = elapsed + 0.05
    end

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
    local photo = getCurrentPhoto()
    if not photo then return false, "No photo selected" end
    local catalog = LrApplication.activeCatalog()
    local done = false
    LrTasks.startAsyncTask(function()
        LrDevelopController.setAutoTone()
        catalog:withWriteAccessDo("Flush AutoTone", function() end, {timeout = 30})
        done = true
    end)
    local elapsed = 0
    while not done and elapsed < 10 do
        LrTasks.sleep(0.05)
        elapsed = elapsed + 0.05
    end
    return true, "Auto tone applied"
end

local function resetAllSettings()
    local catalog = LrApplication.activeCatalog()
    local photo = getCurrentPhoto()
    if not photo then return false, "No photo selected" end
    catalog:withWriteAccessDo("Reset", function()
        LrDevelopController.resetAllDevelopAdjustments()
    end, {timeout = 30})
    return true, "All develop settings reset"
end

local function exportPreview(size)
    log:info("exportPreview called size=" .. tostring(size))
    local photo = getCurrentPhoto()
    if not photo then return nil, "No photo selected" end

    local thumbSize = math.min(tonumber(size) or 1500, 2048)
    local jpegData  = nil

    -- Use requestJpegThumbnail from the preview cache. LrExportSession cannot
    -- be called from the polling-loop task (requires Lightroom's export service
    -- context). The thumbnail may be larger than thumbSize if 1:1 previews are
    -- cached; that is a Lightroom limitation.
    local catalog = LrApplication.activeCatalog()
    local sizes   = { thumbSize }
    if thumbSize > 640 then sizes[#sizes + 1] = 640 end
    if thumbSize > 240 then sizes[#sizes + 1] = 240 end

    for _, sz in ipairs(sizes) do
        local fired    = false
        local cbReason = nil
        catalog:withReadAccessDo(function()
            photo:requestJpegThumbnail(sz, sz, function(jpeg, reason)
                cbReason = tostring(reason)
                if jpeg then jpegData = jpeg end
                fired = true
            end)
        end)
        if not fired then
            local t = 0
            while not fired and t < 2.0 do
                LrTasks.sleep(0.05)
                t = t + 0.05
            end
        end
        log:info("requestJpegThumbnail size=" .. sz
            .. " fired=" .. tostring(fired)
            .. " hasData=" .. tostring(jpegData ~= nil)
            .. " reason=" .. tostring(cbReason))
        if jpegData then break end
    end

    if not jpegData or #jpegData < 3 then
        return nil, "Thumbnail unavailable — try building Standard previews in Lightroom"
    end

    -- Validate JPEG magic bytes; preview cache can occasionally return garbage.
    local b1, b2, b3 = jpegData:byte(1), jpegData:byte(2), jpegData:byte(3)
    if b1 ~= 0xFF or b2 ~= 0xD8 or b3 ~= 0xFF then
        return nil, string.format("Preview has unexpected format (%02X %02X %02X) — rebuild previews", b1, b2, b3)
    end

    log:info("exportPreview ok size=" .. #jpegData)
    -- getRawMetadata requires a read lock; fetch orientation here.
    local orientation = 1
    local catalog = LrApplication.activeCatalog()
    catalog:withReadAccessDo(function()
        local v = photo:getRawMetadata("orientation")
        log:info("getRawMetadata orientation=" .. tostring(v))
        if v then orientation = v end
    end)
    return base64Encode(jpegData), nil, orientation
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
        catalog:withWriteAccessDo("Batch Edit", function()
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
        end, {timeout = 30})
    end

    return true, string.format("Applied to %d photos, %d skipped", count, skipped)
end

local function cropPhoto(params)
    local catalog = LrApplication.activeCatalog()
    local photo = getCurrentPhoto()
    if not photo then return false, "No photo selected" end

    local applied = {}
    catalog:withWriteAccessDo("Crop", function()
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
    end, {timeout = 30})

    if #applied == 0 then
        return false, "No crop parameters provided"
    end
    return true, "Crop applied: " .. table.concat(applied, ", ")
end

-- AI selection subtypes map to maskType="aiSelection" + maskSubType
-- Range mask subtypes map to maskType="rangeMask" + maskSubType
local AI_SUBTYPES = {
    subject=true, sky=true, background=true,
    objects=true, people=true, landscape=true,
}
local RANGE_SUBTYPES = {
    luminance=true, color=true, depth=true,
}
-- Direct maskType values (no subtype needed)
local DIRECT_MASK_TYPES = {
    gradient=true, radialGradient=true, brush=true,
}

local function addMask(maskType, maskParams, adjustments)
    local args = {}

    if AI_SUBTYPES[maskType] then
        args.maskType    = "aiSelection"
        args.maskSubType = maskType
    elseif RANGE_SUBTYPES[maskType] then
        args.maskType    = "rangeMask"
        args.maskSubType = maskType
    elseif DIRECT_MASK_TYPES[maskType] then
        args.maskType = maskType
    else
        return false, "Unknown mask type '" .. tostring(maskType) ..
            "'. Valid: subject, sky, background, objects, people, landscape, " ..
            "luminance, color, depth, gradient, radialGradient, brush"
    end

    if type(maskParams) == "table" then
        for k, v in pairs(maskParams) do
            if k ~= "maskType" and k ~= "maskSubType" then args[k] = v end
        end
    end

    local catalog = LrApplication.activeCatalog()

    -- createNewMask is a develop controller UI operation — withWriteAccessDo rolls it back.
    -- Call directly for all mask types (same as AI masks).
    if args.maskSubType then
        LrDevelopController.createNewMask(args.maskType, args.maskSubType)
    else
        LrDevelopController.createNewMask(args.maskType)
    end

    -- Apply local adjustment sliders to the newly created (currently active) mask.
    if type(adjustments) == "table" and next(adjustments) ~= nil then
        local applied = {}
        for key, value in pairs(adjustments) do
            local lrKey = LOCAL_PARAM_INDEX[key:lower()] or ("local_" .. key)
            LrDevelopController.setValue(lrKey, value)
            table.insert(applied, key)
        end
        if #applied > 0 then
            log:info("Mask adjustments applied: " .. table.concat(applied, ", "))
        end
    end

    log:info("Mask created: " .. maskType)
    return true, "Mask created: " .. maskType
end

local function updateMask(adjustments)
    if type(adjustments) ~= "table" or next(adjustments) == nil then
        return false, "No adjustments provided"
    end
    local applied = {}
    for key, value in pairs(adjustments) do
        local lrKey = LOCAL_PARAM_INDEX[key:lower()] or ("local_" .. key)
        LrDevelopController.setValue(lrKey, value)
        table.insert(applied, key)
    end
    local msg = "Mask updated: " .. table.concat(applied, ", ")
    log:info(msg)
    return true, msg
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

    catalog:withWriteAccessDo("Lens Blur", function()
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
    end, {timeout = 30})

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
        catalog:withWriteAccessDo("Enhance", function()
            LrDevelopController.setEnhance(opts)
        end, {timeout = 30})
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
        response = { success = true, message = "LR MCP Bridge running" }

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
        local b64, err, orientation = exportPreview(req.size)
        if b64 then
            response = { success = true, data = b64, orientation = orientation }
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
        -- Do NOT pcall addMask — withWriteAccessDo yields internally and Lua 5.1
        -- cannot yield across a C pcall boundary.
        local s, msg = addMask(req.maskType, req.params, req.adjustments)
        response = { success = s, message = msg }

    elseif cmd == "update_mask" then
        local s, msg = updateMask(req.adjustments)
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
    -- Bump the persistent global generation counter so any currently-running
    -- loop self-terminates on its next iteration. Using a global (not Server._generation)
    -- ensures tasks from a previous require "Server" call (which created a fresh Server{})
    -- are also evicted — they still read _clrb_gen from the shared Lua environment.
    _clrb_gen = _clrb_gen + 1
    local myGeneration = _clrb_gen
    Server._running    = true

    -- Clean up any stale files from a previous run
    LrFileUtils.delete(REQ_FILE)
    LrFileUtils.delete(RES_FILE)
    log:info("LR MCP Bridge v" .. VERSION .. " started (file IPC mode)")

    local PROC_FILE = REQ_FILE .. ".processing"
    while Server._running and _clrb_gen == myGeneration do
        -- Atomic rename: only one polling loop can claim each request file.
        -- LrFileUtils.move returns true/false (no throw), so check return value directly.
        if LrFileUtils.move(REQ_FILE, PROC_FILE) then
            local f = io.open(PROC_FILE, "r")
            local data = f and f:read("*a")
            if f then f:close() end
            LrFileUtils.delete(PROC_FILE)

            if data and #data > 0 then
                local responseStr = handleRequest(data)
                log:info("Writing response len=" .. #responseStr)
                local rf = io.open(RES_FILE, "w")
                if rf then
                    rf:write(responseStr)
                    rf:close()
                    log:info("Response written OK")
                else
                    log:error("Failed to open RES_FILE for writing")
                end
            end
        end
        LrTasks.sleep(POLL_INTERVAL)
    end

    log:info("LR MCP Bridge stopped")
end

function Server.stop()
    Server._running = false
end

return Server
