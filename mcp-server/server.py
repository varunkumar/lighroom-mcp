#!/usr/bin/env python3
"""
Claude Lightroom MCP Server
Exposes Lightroom develop controls as MCP tools for Claude Desktop.
Communicates with the Lua plugin running inside Lightroom via TCP socket.
"""

import json
import struct
import socket
import sys
from mcp.server import Server
from mcp.server.stdio import stdio_server
from mcp import types

LR_HOST = "localhost"
LR_PORT = 54321
TIMEOUT = 5.0

app = Server("lightroom-bridge")


def send_to_lightroom(command: dict) -> dict:
    """Send a length-prefixed JSON command to the Lightroom plugin."""
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
            sock.settimeout(TIMEOUT)
            sock.connect((LR_HOST, LR_PORT))

            payload = json.dumps(command).encode("utf-8")
            sock.sendall(struct.pack(">I", len(payload)) + payload)

            # Read 4-byte length header
            hdr = b""
            while len(hdr) < 4:
                chunk = sock.recv(4 - len(hdr))
                if not chunk:
                    raise ConnectionError("Connection closed reading header")
                hdr += chunk
            (msg_len,) = struct.unpack(">I", hdr)

            # Read exact payload
            buf = b""
            while len(buf) < msg_len:
                chunk = sock.recv(min(4096, msg_len - len(buf)))
                if not chunk:
                    raise ConnectionError("Connection closed reading payload")
                buf += chunk

            return json.loads(buf.decode("utf-8"))
    except ConnectionRefusedError:
        return {
            "success": False,
            "error": (
                "Cannot connect to Lightroom. Make sure Lightroom Classic is open "
                "and the Claude LR Bridge plugin is active."
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
                "Common parameters: Exposure (-5 to 5), Contrast (-100 to 100), "
                "Highlights (-100 to 100), Shadows (-100 to 100), Whites (-100 to 100), "
                "Blacks (-100 to 100), Clarity (-100 to 100), Dehaze (-100 to 100), "
                "Vibrance (-100 to 100), Saturation (-100 to 100), "
                "Temperature (2000-50000 Kelvin), Tint (-150 to 150), "
                "Sharpness (0-150), LuminanceSmoothing (0-100), ColorNoiseReduction (0-100). "
                "HSL: HueAdjustmentRed/Orange/Yellow/Green/Aqua/Blue/Purple/Magenta (-100 to 100). "
                "Effects: GrainAmount (0-100), PostCropVignetteAmount (-100 to 100)."
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
            result = send_to_lightroom({"command": "apply_settings", "settings": settings})

    else:
        result = {"success": False, "error": f"Unknown tool: {name}"}

    return [types.TextContent(type="text", text=json.dumps(result, indent=2))]


async def main():
    async with stdio_server() as (read_stream, write_stream):
        await app.run(read_stream, write_stream, app.create_initialization_options())


if __name__ == "__main__":
    import asyncio
    asyncio.run(main())
