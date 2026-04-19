"""
Tests for server.py using mock_lr.py as the Lightroom backend.
Run with: pytest tests/ -v   (from mcp-server/ with venv active)
"""
import asyncio
import base64
import os
import subprocess
import sys

import pytest

# Make server.py importable
sys.path.insert(0, os.path.dirname(os.path.dirname(__file__)))


@pytest.fixture()
def mock_lr():
    """Start mock_lr.py as a subprocess; yield; terminate."""
    mock_path = os.path.join(os.path.dirname(os.path.dirname(__file__)), "mock_lr.py")
    proc = subprocess.Popen([sys.executable, mock_path], stdout=subprocess.PIPE)
    # Wait until the server prints its ready line
    proc.stdout.readline()
    yield proc
    proc.terminate()
    proc.wait()


# ── Protocol / existing commands ────────────────────────────────────────────

def test_ping(mock_lr):
    import server
    result = server.send_to_lightroom({"command": "ping"})
    assert result["success"] is True


def test_get_settings_defaults(mock_lr):
    import server
    result = server.send_to_lightroom({"command": "get_settings"})
    assert result["success"] is True
    s = result["data"]["settings"]
    assert s["Exposure"] == 0
    assert s["Temperature"] == 6500


def test_apply_settings_persists(mock_lr):
    import server
    server.send_to_lightroom({"command": "apply_settings", "settings": {"Exposure": 1.5}})
    result = server.send_to_lightroom({"command": "get_settings"})
    assert result["data"]["settings"]["Exposure"] == 1.5


def test_auto_tone(mock_lr):
    import server
    result = server.send_to_lightroom({"command": "auto_tone"})
    assert result["success"] is True
    settings = server.send_to_lightroom({"command": "get_settings"})["data"]["settings"]
    assert settings["Highlights"] == -30


def test_reset_clears_settings(mock_lr):
    import server
    server.send_to_lightroom({"command": "apply_settings", "settings": {"Exposure": 2.0}})
    server.send_to_lightroom({"command": "reset"})
    result = server.send_to_lightroom({"command": "get_settings"})
    assert result["data"]["settings"]["Exposure"] == 0


# ── export_preview ───────────────────────────────────────────────────────────

def test_export_preview_returns_jpeg(mock_lr):
    import server
    result = server.send_to_lightroom({"command": "export_preview", "size": 200})
    assert result["success"] is True
    raw = base64.b64decode(result["data"])
    assert raw[:2] == b"\xff\xd8", "Response is not a JPEG"


def test_export_preview_mcp_tool_returns_image_content(mock_lr):
    import server
    from mcp import types
    contents = asyncio.run(server.call_tool("lr_export_preview", {}))
    assert len(contents) == 1
    img = contents[0]
    assert isinstance(img, types.ImageContent)
    assert img.media_type == "image/jpeg"
    raw = base64.b64decode(img.data)
    assert raw[:2] == b"\xff\xd8"


# ── batch_apply_settings ────────────────────────────────────────────────────

def test_batch_apply_settings_protocol(mock_lr):
    import server
    result = server.send_to_lightroom({
        "command": "batch_apply_settings",
        "settings": {"LuminanceSmoothing": 50},
    })
    assert result["success"] is True
    assert result["applied"] == 3   # mock has 3 default photos
    assert result["skipped"] == 0


def test_batch_apply_settings_mcp_tool(mock_lr):
    import json
    import server
    from mcp import types
    contents = asyncio.run(server.call_tool(
        "lr_batch_apply_settings",
        {"settings": {"ColorNoiseReduction": 40}},
    ))
    assert len(contents) == 1
    assert isinstance(contents[0], types.TextContent)
    data = json.loads(contents[0].text)
    assert data["applied"] == 3
    assert data["skipped"] == 0
