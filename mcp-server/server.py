#!/usr/bin/env python3
"""
Claude Lightroom MCP Server
Exposes Lightroom develop controls as MCP tools for Claude Desktop.
Communicates with the Lua plugin running inside Lightroom via file-based IPC.
"""

import json
import os
import time

from mcp import types
from mcp.server import Server
from mcp.server.stdio import stdio_server

REQ_FILE = os.environ.get("LR_MCP_REQ", "/tmp/lr_mcp_req.json")
RES_FILE = os.environ.get("LR_MCP_RES", "/tmp/lr_mcp_res.json")
TIMEOUT = 10.0   # seconds to wait for Lua to respond
POLL = 0.05   # seconds between polls

app = Server("lightroom-bridge")


def send_to_lightroom(command: dict, timeout: float = TIMEOUT) -> dict:
    """Write a command to the request file and wait for the response file."""
    try:
        # Clean up any stale response from a previous call
        if os.path.exists(RES_FILE):
            os.remove(RES_FILE)

        # Write request atomically via a temp file + rename
        tmp = REQ_FILE + ".tmp"
        with open(tmp, "w") as f:
            json.dump(command, f)
        os.replace(tmp, REQ_FILE)

        # Poll for the response file
        elapsed = 0.0
        while elapsed < timeout:
            if os.path.exists(RES_FILE):
                try:
                    with open(RES_FILE, "r") as f:
                        data = f.read()
                    result = json.loads(data)  # parse before deleting
                    os.remove(RES_FILE)
                    return result
                except (json.JSONDecodeError, ValueError):
                    pass  # partial write in progress — don't delete, retry
                except Exception:
                    try:
                        os.remove(RES_FILE)
                    except Exception:
                        pass
            time.sleep(POLL)
            elapsed += POLL

        # Clean up request file if Lua never read it
        if os.path.exists(REQ_FILE):
            os.remove(REQ_FILE)
        return {
            "success": False,
            "error": (
                "Lightroom did not respond in time. "
                "Make sure Lightroom Classic is open and the Claude LR Bridge plugin is running."
            ),
        }
    except Exception as e:
        return {"success": False, "error": str(e)}


@app.list_tools()
async def list_tools() -> list[types.Tool]:
    return [
        types.Tool(
            name="lr_apply_settings",
            description=(
                "Apply develop settings to the currently selected photo in Lightroom Classic. "
                "Pass a dict of parameter names and values. "
                "Tone: Exposure (-5 to 5), Contrast (-100 to 100), "
                "Highlights (-100 to 100), Shadows (-100 to 100), Whites (-100 to 100), "
                "Blacks (-100 to 100). "
                "Presence: Clarity (-100 to 100), Texture (-100 to 100), "
                "Dehaze (-100 to 100), Vibrance (-100 to 100), Saturation (-100 to 100). "
                "Color: Temperature (2000-50000 K), Tint (-150 to 150). "
                "Detail: Sharpness (0-150), LuminanceSmoothing (0-100), ColorNoiseReduction (0-100). "
                "HSL: HueAdjustmentRed/Orange/Yellow/Green/Aqua/Blue/Purple/Magenta (-100 to 100). "
                "Effects: GrainAmount (0-100), PostCropVignetteAmount (-100 to 100). "
                "Transform: PerspectiveVertical/Horizontal (-100 to 100), PerspectiveRotate (-10 to 10), "
                "PerspectiveScale (50-150), PerspectiveAspect (-100 to 100), "
                "PerspectiveX/Y (-100 to 100), PerspectiveUpright (0=off,1=auto,2=level,3=vertical,4=full). "
                "Color Grading: ColorGradeBlending (0-100), "
                "ColorGradeGlobalHue/Lum/Sat, ColorGradeMidtoneHue/Lum/Sat (Hue 0-360, Lum/Sat -100 to 100), "
                "ColorGradeHighlightLum (-100 to 100), ColorGradeShadowLum (-100 to 100). "
                "B&W Mix: GrayMixerRed/Orange/Yellow/Green/Aqua/Blue/Purple/Magenta (-100 to 100). "
                "Split Toning: SplitToningBalance (-100 to 100), SplitToningHighlightHue/Saturation, SplitToningShadowHue/Saturation. "
                "Defringe: DefringeGreenAmount/HueHi/HueLo, DefringePurpleAmount/HueHi/HueLo (0-100)."
            ),
            inputSchema={
                "type": "object",
                "properties": {
                    "settings": {
                        "type": "object",
                        "description": "Key-value pairs of Lightroom develop parameters",
                        "additionalProperties": {"type": "number"},
                    }
                },
                "required": ["settings"],
            },
        ),
        types.Tool(
            name="lr_get_settings",
            description=(
                "Get the current develop settings and metadata of the selected photo "
                "in Lightroom Classic. Returns all current slider values, filename, and rating."
            ),
            inputSchema={"type": "object", "properties": {}},
        ),
        types.Tool(
            name="lr_auto_tone",
            description=(
                "Apply Lightroom's Auto Tone to the selected photo. "
                "This is equivalent to clicking the Auto button in the Tone section."
            ),
            inputSchema={"type": "object", "properties": {}},
        ),
        types.Tool(
            name="lr_reset",
            description=(
                "Reset all develop settings on the selected photo back to defaults. "
                "Use with caution - this clears all edits."
            ),
            inputSchema={"type": "object", "properties": {}},
        ),
        types.Tool(
            name="lr_ping",
            description="Check if the Lightroom bridge is connected and running.",
            inputSchema={"type": "object", "properties": {}},
        ),
        types.Tool(
            name="lr_export_preview",
            description=(
                "Export a JPEG preview of the currently selected photo in Lightroom Classic "
                "and return it as an image. Claude can see the photo and give visual feedback "
                "on develop settings, tone, color, composition, etc. "
                "Call this before and after applying settings to compare results."
            ),
            inputSchema={
                "type": "object",
                "properties": {
                    "size": {
                        "type": "integer",
                        "description": "Long-edge pixel size of the JPEG (default 1500, max 2048)",
                    }
                },
            },
        ),
        types.Tool(
            name="lr_batch_apply_settings",
            description=(
                "Apply develop settings to ALL currently selected photos in Lightroom Classic. "
                "Useful for batch operations like denoising a series of shots, "
                "applying a consistent grade across a set, etc. "
                "Uses the same parameter names and ranges as lr_apply_settings."
            ),
            inputSchema={
                "type": "object",
                "properties": {
                    "settings": {
                        "type": "object",
                        "description": "Key-value pairs of Lightroom develop parameters to apply to all selected photos",
                        "additionalProperties": {"type": "number"},
                    }
                },
                "required": ["settings"],
            },
        ),
        types.Tool(
            name="lr_crop",
            description=(
                "Crop and/or straighten the selected photo in Lightroom Classic. "
                "Specify crop bounds as normalized coordinates (0.0–1.0) and/or a straighten angle. "
                "All parameters are optional — only provided values are changed. "
                "angle: straighten rotation in degrees (-45 to 45). "
                "CropTop/CropBottom/CropLeft/CropRight: crop boundary (0.0=edge, 1.0=opposite edge)."
            ),
            inputSchema={
                "type": "object",
                "properties": {
                    "angle": {"type": "number", "description": "Straighten angle in degrees (-45 to 45)"},
                    "CropTop":    {"type": "number", "description": "Top crop boundary (0.0–1.0)"},
                    "CropBottom": {"type": "number", "description": "Bottom crop boundary (0.0–1.0)"},
                    "CropLeft":   {"type": "number", "description": "Left crop boundary (0.0–1.0)"},
                    "CropRight":  {"type": "number", "description": "Right crop boundary (0.0–1.0)"},
                },
            },
        ),
        types.Tool(
            name="lr_lens_blur",
            description=(
                "Apply AI Lens Blur (depth-of-field effect) to the selected photo in Lightroom Classic. "
                "Uses an AI-generated depth map to blur foreground/background. "
                "Parameters: "
                "active (bool, default true — enable/disable lens blur), "
                "amount (0-100, blur strength), "
                "bokeh (shape of out-of-focus highlights: 'Circle', 'SoapBubble', 'Blade', 'Ring', 'Anamorphic'), "
                "catEye (0-100, cat-eye vignetting on bokeh), "
                "highlightsBoost (0-100, boost specular highlights in blur), "
                "focalRangeFromSubject (bool, auto-set focal range to focus on the main subject)."
            ),
            inputSchema={
                "type": "object",
                "properties": {
                    "active": {"type": "boolean", "description": "Enable or disable lens blur (default true)"},
                    "amount": {"type": "number", "description": "Blur strength (0-100)"},
                    "bokeh": {
                        "type": "string",
                        "description": "Bokeh shape",
                        "enum": ["Circle", "SoapBubble", "Blade", "Ring", "Anamorphic"],
                    },
                    "catEye": {"type": "number", "description": "Cat-eye vignetting on bokeh highlights (0-100)"},
                    "highlightsBoost": {"type": "number", "description": "Boost specular highlights in blur (0-100)"},
                    "focalRangeFromSubject": {
                        "type": "boolean",
                        "description": "Auto-set focal range from the AI-detected subject",
                    },
                },
            },
        ),
        types.Tool(
            name="lr_enhance",
            description=(
                "Run Lightroom's AI Enhance on the selected photo. "
                "Supports: AI Denoise (reduces noise using machine learning), "
                "Super Resolution (upscales image to 2× using AI), "
                "Raw Details (improves demosaicing of RAW files). "
                "Note: These operations create a new enhanced DNG and may take time to process. "
                "Parameters: denoise (bool), denoiseAmount (0-100, strength of noise reduction), "
                "superRes (bool), rawDetails (bool)."
            ),
            inputSchema={
                "type": "object",
                "properties": {
                    "denoise": {"type": "boolean", "description": "Enable AI Denoise"},
                    "denoiseAmount": {"type": "number", "description": "Denoise strength (0-100)"},
                    "superRes": {"type": "boolean", "description": "Enable Super Resolution (2× upscale)"},
                    "rawDetails": {"type": "boolean", "description": "Enable Raw Details (improved RAW demosaicing)"},
                },
            },
        ),
        types.Tool(
            name="lr_add_mask",
            description=(
                "Add a mask to the selected photo in Lightroom Classic. "
                "AI types (fully automatic): 'subject', 'sky', 'background', 'objects', 'people', 'landscape'. "
                "Range types (automatic): 'luminance', 'color', 'depth'. "
                "Manual types (user must draw after calling): 'gradient' (linear), 'radialGradient' (elliptical), 'brush'. "
                "All types accept an optional 'adjustments' object to apply local develop sliders to the new mask."
            ),
            inputSchema={
                "type": "object",
                "properties": {
                    "maskType": {
                        "type": "string",
                        "description": "Type of mask to create",
                        "enum": ["subject", "sky", "background", "objects", "people", "landscape",
                                 "luminance", "color", "depth",
                                 "gradient", "radialGradient", "brush"],
                    },
                    "params": {
                        "type": "object",
                        "description": "Optional mask parameters (e.g. angle, midpoint, feather for gradients)",
                        "additionalProperties": True,
                    },
                    "adjustments": {
                        "type": "object",
                        "description": (
                            "Optional develop sliders to apply to the new mask "
                            "(e.g. {\"Exposure\": 0.5, \"Highlights\": -30, \"Saturation\": 20}). "
                            "Keys are the same parameter names as lr_apply_settings but applied "
                            "locally to only this mask. Supported: Exposure, Contrast, Highlights, "
                            "Shadows, Whites, Blacks, Clarity, Texture, Dehaze, Vibrance, "
                            "Saturation, Temperature, Tint, Sharpness, LuminanceNoise, ColorNoise, "
                            "MoireFilter, Defringe, ToningHue, ToningSaturation."
                        ),
                        "additionalProperties": True,
                    },
                },
                "required": ["maskType"],
            },
        ),
        types.Tool(
            name="lr_update_mask",
            description=(
                "Update the local develop sliders on the mask that is currently selected "
                "in Lightroom's Masks panel. Select the target mask in LR first, then call "
                "this tool with the slider values to apply. Supported: Exposure, Contrast, "
                "Highlights, Shadows, Whites, Blacks, Clarity, Texture, Dehaze, Vibrance, "
                "Saturation, Temperature, Tint, Sharpness, LuminanceNoise, ColorNoise, "
                "MoireFilter, Defringe, ToningHue, ToningSaturation."
            ),
            inputSchema={
                "type": "object",
                "properties": {
                    "adjustments": {
                        "type": "object",
                        "description": "Slider values to apply to the active mask (e.g. {\"Exposure\": 0.5, \"Highlights\": -30})",
                        "additionalProperties": True,
                    },
                },
                "required": ["adjustments"],
            },
        ),
    ]


@app.call_tool()
async def call_tool(name: str, arguments: dict) -> list[types.TextContent]:
    if name == "lr_ping":
        result = send_to_lightroom({"command": "ping"})

    elif name == "lr_get_settings":
        result = send_to_lightroom({"command": "get_settings"})

    elif name == "lr_auto_tone":
        result = send_to_lightroom({"command": "auto_tone"})

    elif name == "lr_reset":
        result = send_to_lightroom({"command": "reset"})

    elif name == "lr_apply_settings":
        settings = arguments.get("settings", {})
        if not settings:
            result = {"success": False, "error": "No settings provided"}
        else:
            result = send_to_lightroom(
                {"command": "apply_settings", "settings": settings}, timeout=45.0)

    elif name == "lr_export_preview":
        size = min(int(arguments.get("size", 1500)), 2048)
        result = send_to_lightroom(
            {"command": "export_preview", "size": size}, timeout=30.0)
        if result.get("success") and result.get("data"):
            return [
                types.ImageContent(
                    type="image",
                    mimeType="image/jpeg",
                    data=result["data"],
                )
            ]
        return [types.TextContent(type="text", text=json.dumps(result, indent=2))]

    elif name == "lr_batch_apply_settings":
        settings = arguments.get("settings", {})
        if not settings:
            result = {"success": False, "error": "No settings provided"}
        else:
            result = send_to_lightroom(
                {"command": "batch_apply_settings", "settings": settings})

    elif name == "lr_crop":
        params = {k: v for k, v in arguments.items()}
        if not params:
            result = {"success": False, "error": "No crop parameters provided"}
        else:
            result = send_to_lightroom({"command": "crop", "params": params})

    elif name == "lr_add_mask":
        mask_type = arguments.get("maskType")
        if not mask_type:
            result = {"success": False, "error": "maskType is required"}
        else:
            result = send_to_lightroom({
                "command": "add_mask",
                "maskType": mask_type,
                "params": arguments.get("params", {}),
                "adjustments": arguments.get("adjustments", {}),
            }, timeout=120.0)

    elif name == "lr_update_mask":
        adjustments = arguments.get("adjustments", {})
        if not adjustments:
            result = {"success": False, "error": "No adjustments provided"}
        else:
            result = send_to_lightroom({
                "command": "update_mask",
                "adjustments": adjustments,
            })

    elif name == "lr_lens_blur":
        params = {k: v for k, v in arguments.items()}
        if not params:
            result = {"success": False,
                      "error": "No lens blur parameters provided"}
        else:
            result = send_to_lightroom(
                {"command": "lens_blur", "params": params})

    elif name == "lr_enhance":
        params = {k: v for k, v in arguments.items()}
        if not params:
            result = {
                "success": False, "error": "No enhance parameters provided. Use: denoise, denoiseAmount, superRes, rawDetails"}
        else:
            result = send_to_lightroom(
                {"command": "enhance", "params": params})

    else:
        result = {"success": False, "error": f"Unknown tool: {name}"}

    return [types.TextContent(type="text", text=json.dumps(result, indent=2))]


async def main():
    async with stdio_server() as (read_stream, write_stream):
        await app.run(read_stream, write_stream, app.create_initialization_options())


if __name__ == "__main__":
    import asyncio
    asyncio.run(main())
