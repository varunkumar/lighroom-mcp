# Phase 2 & 3 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Harden the TCP protocol with length-prefix framing, add visual preview export and batch settings tools, and create a stateful mock server for testing without Lightroom.

**Architecture:** The Lua plugin and Python MCP server both migrate from newline-delimited to 4-byte big-endian uint32 length-prefix framing (deployed together, no versioning needed). Two new tools — `lr_export_preview` (returns MCP ImageContent) and `lr_batch_apply_settings` (applies to all selected photos) — are added to both the Python and Lua layers. A standalone `mock_lr.py` simulates the Lua server over the same protocol for Python-side testing.

**Tech Stack:** Python 3, `mcp>=1.0.0`, `Pillow` (mock only), `pytest`, Lua 5.1 (Lightroom SDK), `LrThumbnailRequest`, `LrSockets`.

---

## File Map

| File | Action | Responsibility |
|---|---|---|
| `mcp-server/mock_lr.py` | **Create** | Stateful mock TCP server (dev/test only) |
| `mcp-server/requirements-dev.txt` | **Create** | Dev deps: Pillow, pytest |
| `mcp-server/tests/__init__.py` | **Create** | Empty, marks test package |
| `mcp-server/tests/test_server.py` | **Create** | pytest tests for send_to_lightroom + call_tool |
| `mcp-server/server.py` | **Modify** | Length-prefix framing + 2 new tools |
| `lrplugin/claude-lr-bridge.lrdevplugin/Server.lua` | **Modify** | Length-prefix framing + base64 + 2 new handlers |
| `CLAUDE.md` | **Modify** | Tools reference, parameter ranges, mock usage, wire protocol |

---

## Task 1: Create mock_lr.py

**Files:**
- Create: `mcp-server/mock_lr.py`

- [ ] **Step 1: Write mock_lr.py**

```python
#!/usr/bin/env python3
"""
Mock Lightroom TCP server for testing without Lightroom open.
Dev/test only — never deployed or referenced by Claude Desktop.

Usage:
    python3 mock_lr.py              # port 54321
    python3 mock_lr.py --port 54322
"""

import argparse
import base64
import io
import json
import socket
import struct
import threading

try:
    from PIL import Image
    HAS_PILLOW = True
except ImportError:
    HAS_PILLOW = False

_DEFAULT_SETTINGS = {
    "Exposure": 0, "Contrast": 0, "Highlights": 0, "Shadows": 0,
    "Whites": 0, "Blacks": 0, "Clarity": 0, "Dehaze": 0,
    "Vibrance": 0, "Saturation": 0, "Temperature": 6500, "Tint": 0,
    "Sharpness": 25, "LuminanceSmoothing": 0, "ColorNoiseReduction": 25,
    "HueAdjustmentRed": 0, "HueAdjustmentOrange": 0, "HueAdjustmentYellow": 0,
    "HueAdjustmentGreen": 0, "HueAdjustmentAqua": 0, "HueAdjustmentBlue": 0,
    "HueAdjustmentPurple": 0, "HueAdjustmentMagenta": 0,
    "SaturationAdjustmentRed": 0, "SaturationAdjustmentOrange": 0,
    "SaturationAdjustmentYellow": 0, "SaturationAdjustmentGreen": 0,
    "SaturationAdjustmentAqua": 0, "SaturationAdjustmentBlue": 0,
    "SaturationAdjustmentPurple": 0, "SaturationAdjustmentMagenta": 0,
    "LuminanceAdjustmentRed": 0, "LuminanceAdjustmentOrange": 0,
    "LuminanceAdjustmentYellow": 0, "LuminanceAdjustmentGreen": 0,
    "LuminanceAdjustmentAqua": 0, "LuminanceAdjustmentBlue": 0,
    "LuminanceAdjustmentPurple": 0, "LuminanceAdjustmentMagenta": 0,
    "GrainAmount": 0, "PostCropVignetteAmount": 0,
    "PerspectiveVertical": 0, "PerspectiveHorizontal": 0, "PerspectiveRotate": 0,
}

_AUTO_TONE = {
    "Exposure": 0.5, "Highlights": -30, "Shadows": 20, "Whites": 10, "Blacks": -10,
}

_DEFAULT_PHOTOS = ["DSC_001.NEF", "DSC_002.NEF", "DSC_003.NEF"]


def _make_jpeg(settings: dict, size: int) -> str:
    """Return a base64-encoded JPEG; color shifts with Temperature."""
    temp = settings.get("Temperature", 6500)
    ratio = max(0.0, min(1.0, (temp - 2000) / 48000))
    r = int(220 * (0.5 + 0.5 * (1 - ratio)))
    g = 180
    b = int(220 * (0.3 + 0.7 * ratio))
    if HAS_PILLOW:
        img = Image.new("RGB", (size, max(1, size * 2 // 3)), color=(r, g, b))
        buf = io.BytesIO()
        img.save(buf, format="JPEG", quality=85)
        return base64.b64encode(buf.getvalue()).decode()
    # Minimal valid 1×1 white JPEG when Pillow is absent
    minimal = (
        b"\xff\xd8\xff\xe0\x00\x10JFIF\x00\x01\x01\x00\x00\x01\x00\x01\x00\x00"
        b"\xff\xdb\x00C\x00\x08\x06\x06\x07\x06\x05\x08\x07\x07\x07\t\t"
        b"\x08\n\x0c\x14\r\x0c\x0b\x0b\x0c\x19\x12\x13\x0f\x14\x1d\x1a"
        b"\x1f\x1e\x1d\x1a\x1c\x1c $.' \",#\x1c\x1c(7),01444\x1f'9=82<.342\xc7"
        b"\xff\xc0\x00\x0b\x08\x00\x01\x00\x01\x01\x01\x11\x00"
        b"\xff\xc4\x00\x1f\x00\x00\x01\x05\x01\x01\x01\x01\x01\x01\x00\x00"
        b"\x00\x00\x00\x00\x00\x00\x01\x02\x03\x04\x05\x06\x07\x08\t\n\x0b"
        b"\xff\xda\x00\x08\x01\x01\x00\x00?\x00\xf5\x00\xff\xd9"
    )
    return base64.b64encode(minimal).decode()


def _recv(sock: socket.socket) -> dict:
    hdr = b""
    while len(hdr) < 4:
        chunk = sock.recv(4 - len(hdr))
        if not chunk:
            raise ConnectionError("closed")
        hdr += chunk
    (length,) = struct.unpack(">I", hdr)
    buf = b""
    while len(buf) < length:
        chunk = sock.recv(min(4096, length - len(buf)))
        if not chunk:
            raise ConnectionError("closed")
        buf += chunk
    return json.loads(buf.decode())


def _send(sock: socket.socket, data: dict) -> None:
    payload = json.dumps(data).encode()
    sock.sendall(struct.pack(">I", len(payload)) + payload)


class _State:
    def __init__(self):
        self.settings = dict(_DEFAULT_SETTINGS)
        self.photos = list(_DEFAULT_PHOTOS)
        self.rating = 0
        self._lock = threading.Lock()

    def handle(self, req: dict) -> dict:
        cmd = req.get("command")
        with self._lock:
            if cmd == "ping":
                return {"success": True, "message": "Mock LR Bridge running"}

            if cmd == "get_settings":
                return {
                    "success": True,
                    "data": {
                        "filename": self.photos[0] if self.photos else "none",
                        "rating": self.rating,
                        "settings": dict(self.settings),
                    },
                }

            if cmd == "apply_settings":
                s = req.get("settings", {})
                self.settings.update(s)
                return {"success": True, "message": f"Applied: {', '.join(s)}"}

            if cmd == "batch_apply_settings":
                s = req.get("settings", {})
                self.settings.update(s)
                n = len(self.photos)
                return {"success": True, "applied": n, "skipped": 0,
                        "message": f"Applied to {n} photos, 0 skipped"}

            if cmd == "auto_tone":
                self.settings.update(_AUTO_TONE)
                return {"success": True, "message": "Auto tone applied"}

            if cmd == "reset":
                self.settings = dict(_DEFAULT_SETTINGS)
                return {"success": True, "message": "All develop settings reset"}

            if cmd == "export_preview":
                size = min(int(req.get("size", 200)), 2048)
                b64 = _make_jpeg(self.settings, size)
                return {
                    "success": True,
                    "data": b64,
                    "width": size,
                    "height": size * 2 // 3,
                }

            return {"success": False, "error": f"Unknown command: {cmd}"}


def _handle_client(conn: socket.socket, state: _State) -> None:
    try:
        req = _recv(conn)
        _send(conn, state.handle(req))
    except Exception as exc:
        try:
            _send(conn, {"success": False, "error": str(exc)})
        except Exception:
            pass
    finally:
        conn.close()


def serve(port: int = 54321) -> None:
    state = _State()
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("localhost", port))
    srv.listen(5)
    print(f"Mock LR Bridge listening on localhost:{port}", flush=True)
    try:
        while True:
            conn, _ = srv.accept()
            threading.Thread(target=_handle_client, args=(conn, state), daemon=True).start()
    except KeyboardInterrupt:
        pass
    finally:
        srv.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Mock Lightroom TCP server (dev/test only)")
    parser.add_argument("--port", type=int, default=54321)
    serve(parser.parse_args().port)
```

- [ ] **Step 2: Verify it runs**

```bash
cd mcp-server
python3 mock_lr.py &
sleep 0.5
python3 -c "
import socket, struct, json
s = socket.socket()
s.connect(('localhost', 54321))
payload = json.dumps({'command':'ping'}).encode()
s.sendall(struct.pack('>I', len(payload)) + payload)
hdr = s.recv(4)
(n,) = struct.unpack('>I', hdr)
print(json.loads(s.recv(n)))
s.close()
"
kill %1
```

Expected output: `{'success': True, 'message': 'Mock LR Bridge running'}`

- [ ] **Step 3: Commit**

```bash
git add mcp-server/mock_lr.py
git commit -m "feat: add stateful mock Lightroom TCP server"
```

---

## Task 2: Create requirements-dev.txt and test scaffold

**Files:**
- Create: `mcp-server/requirements-dev.txt`
- Create: `mcp-server/tests/__init__.py`
- Create: `mcp-server/tests/test_server.py`

- [ ] **Step 1: Write requirements-dev.txt**

```
# mcp-server/requirements-dev.txt
Pillow>=10.0.0
pytest>=8.0.0
```

- [ ] **Step 2: Install dev deps**

```bash
cd mcp-server
source venv/bin/activate
pip install -r requirements-dev.txt
```

Expected: Pillow and pytest install without errors.

- [ ] **Step 3: Create tests/__init__.py**

Empty file:
```bash
touch mcp-server/tests/__init__.py
```

- [ ] **Step 4: Write test_server.py**

```python
# mcp-server/tests/test_server.py
"""
Tests for server.py using mock_lr.py as the Lightroom backend.
Run with: pytest tests/ -v   (from mcp-server/ with venv active)
"""
import asyncio
import base64
import os
import subprocess
import sys
import time

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
    import server
    from mcp import types
    contents = asyncio.run(server.call_tool(
        "lr_batch_apply_settings",
        {"settings": {"ColorNoiseReduction": 40}},
    ))
    assert len(contents) == 1
    assert isinstance(contents[0], types.TextContent)
    assert "3" in contents[0].text   # 3 photos applied
```

- [ ] **Step 5: Run tests — confirm they all FAIL**

```bash
cd mcp-server
source venv/bin/activate
pytest tests/test_server.py -v
```

Expected: All tests fail. `test_ping` and others fail with `json.JSONDecodeError` or `ConnectionResetError` because `server.py` still uses newline framing but `mock_lr.py` uses length-prefix framing. `test_export_preview_*` and `test_batch_*` fail with `Unknown tool` because those tools don't exist yet.

- [ ] **Step 6: Commit scaffold**

```bash
git add mcp-server/requirements-dev.txt mcp-server/tests/
git commit -m "test: add pytest scaffold and failing tests for new features"
```

---

## Task 3: Update server.py — length-prefix framing

**Files:**
- Modify: `mcp-server/server.py`

- [ ] **Step 1: Replace send_to_lightroom with length-prefix version**

Replace the entire `send_to_lightroom` function (lines 22–51) in `mcp-server/server.py`:

```python
import struct   # add to imports at top of file

def send_to_lightroom(command: dict) -> dict:
    """Send a length-prefixed JSON command to the Lightroom plugin."""
    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
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

        sock.close()
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
```

Also add `import struct` at the top of the file after `import json`.

- [ ] **Step 2: Run the protocol tests — they should now pass**

```bash
cd mcp-server
source venv/bin/activate
pytest tests/test_server.py -v -k "ping or get_settings or apply_settings or auto_tone or reset"
```

Expected: `test_ping`, `test_get_settings_defaults`, `test_apply_settings_persists`, `test_auto_tone`, `test_reset_clears_settings` all PASS. The `export_preview` and `batch` tests still fail.

- [ ] **Step 3: Commit**

```bash
git add mcp-server/server.py
git commit -m "feat: replace newline framing with 4-byte length-prefix protocol"
```

---

## Task 4: Add lr_export_preview to server.py

**Files:**
- Modify: `mcp-server/server.py`

- [ ] **Step 1: Add lr_export_preview tool definition**

In `list_tools()`, after the `lr_ping` tool definition and before the closing `]`, add:

```python
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
```

- [ ] **Step 2: Add handlers in call_tool**

In `call_tool`, replace the final `else` block:

```python
    elif name == "lr_export_preview":
        size = min(int(arguments.get("size", 1500)), 2048)
        result = send_to_lightroom({"command": "export_preview", "size": size})
        if result.get("success") and result.get("data"):
            return [
                types.ImageContent(
                    type="image",
                    media_type="image/jpeg",
                    data=result["data"],
                )
            ]
        return [types.TextContent(type="text", text=json.dumps(result, indent=2))]

    elif name == "lr_batch_apply_settings":
        settings = arguments.get("settings", {})
        if not settings:
            result = {"success": False, "error": "No settings provided"}
        else:
            result = send_to_lightroom({"command": "batch_apply_settings", "settings": settings})

    else:
        result = {"success": False, "error": f"Unknown tool: {name}"}

    return [types.TextContent(type="text", text=json.dumps(result, indent=2))]
```

- [ ] **Step 3: Run all tests**

```bash
cd mcp-server
source venv/bin/activate
pytest tests/test_server.py -v
```

Expected: All 9 tests PASS.

- [ ] **Step 4: Commit**

```bash
git add mcp-server/server.py
git commit -m "feat: add lr_export_preview and lr_batch_apply_settings MCP tools"
```

---

## Task 5: Update Server.lua — length-prefix framing + base64

**Files:**
- Modify: `lrplugin/claude-lr-bridge.lrdevplugin/Server.lua`

- [ ] **Step 1: Add base64 encoder and framing helpers at the top of Server.lua**

After the `local LrJSON = import "LrJSON"` line, add:

```lua
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
```

- [ ] **Step 2: Replace the client-handling block in Server.start()**

Find the `LrTasks.startAsyncTask(function()` block inside `Server.start()` that reads until newline and replace the entire inner block:

```lua
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
```

- [ ] **Step 3: Verify framing with mock_lr.py (manual)**

Start `mock_lr.py`, then use `nc` to confirm the Lua framing helpers match the Python mock's framing. Since Lua code runs inside Lightroom, we verify correctness by comparing the Python mock's `_recv`/`_send` with the Lua `recvMessage`/`sendMessage` side-by-side:

- Python sends: `struct.pack(">I", N)` + N bytes of JSON
- Lua reads: `b1*16777216 + b2*65536 + b3*256 + b4` — same big-endian decode ✓
- Lua sends: `string.char(...)` header + payload
- Python reads: `struct.unpack(">I", hdr)` — same big-endian decode ✓

- [ ] **Step 4: Commit**

```bash
git add lrplugin/claude-lr-bridge.lrdevplugin/Server.lua
git commit -m "feat: replace newline framing with 4-byte length-prefix in Lua server"
```

---

## Task 6: Add export_preview handler to Server.lua

**Files:**
- Modify: `lrplugin/claude-lr-bridge.lrdevplugin/Server.lua`

- [ ] **Step 1: Add exportPreview function**

After the `resetAllSettings` function and before `handleRequest`, add:

```lua
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
```

- [ ] **Step 2: Add export_preview branch in handleRequest**

Inside `handleRequest`, after the `elseif cmd == "reset"` block and before the `else`:

```lua
    elseif cmd == "export_preview" then
        local b64, err = exportPreview(req.size)
        if b64 then
            response = { success = true, data = b64 }
        else
            response = { success = false, error = err }
        end
```

- [ ] **Step 3: Add LrApplication import for module-level use (already imported — verify)**

`LrApplication` is already imported at line 10. No change needed.

- [ ] **Step 4: Commit**

```bash
git add lrplugin/claude-lr-bridge.lrdevplugin/Server.lua
git commit -m "feat: add export_preview handler to Lua server using LrThumbnailRequest"
```

---

## Task 7: Add batch_apply_settings handler to Server.lua

**Files:**
- Modify: `lrplugin/claude-lr-bridge.lrdevplugin/Server.lua`

- [ ] **Step 1: Add batchApplySettings function**

After the `exportPreview` function, add:

```lua
local function batchApplySettings(settings)
    local catalog = LrApplication.activeCatalog()
    local photos  = catalog:getTargetPhotos()   -- all selected photos

    if not photos or #photos == 0 then
        return false, "No photos selected"
    end

    LrDevelopController.revealPanelForParameter("Exposure")

    local count   = 0
    local skipped = 0

    catalog:withWriteAccessDo("Claude Batch Edit", function()
        for _, photo in ipairs(photos) do
            catalog:setSelectedPhotos(photo, { photo })
            for key, value in pairs(settings) do
                local paramName = PARAM_INDEX[key:lower()] or key
                local ok = pcall(function()
                    LrDevelopController.setValue(paramName, tonumber(value) or value)
                end)
                if not ok then skipped = skipped + 1 end
            end
            count = count + 1
        end
    end)

    return true, string.format("Applied to %d photos, %d skipped", count, skipped)
end
```

- [ ] **Step 2: Add batch_apply_settings branch in handleRequest**

After the `elseif cmd == "export_preview"` block:

```lua
    elseif cmd == "batch_apply_settings" then
        local ok, msg = batchApplySettings(req.settings or {})
        response = { success = ok, message = msg }
```


- [ ] **Step 3: Commit**

```bash
git add lrplugin/claude-lr-bridge.lrdevplugin/Server.lua
git commit -m "feat: add batch_apply_settings handler to Lua server"
```

---

## Task 8: Update CLAUDE.md

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: Replace CLAUDE.md with updated version**

Replace the entire contents of `CLAUDE.md` with:

```markdown
# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Architecture

```
Claude Desktop → MCP Server (Python/stdio) → TCP Socket (port 54321) → Lua Plugin → LrDevelopController
```

Two components that must work in tandem:

- **`mcp-server/server.py`** — Python MCP server communicating with Claude Desktop over stdio. Sends length-prefixed JSON commands to the Lua plugin and returns results as MCP tool responses.
- **`lrplugin/claude-lr-bridge.lrdevplugin/`** — Lightroom Classic plugin (Lua) that runs a TCP server on port 54321 inside Lightroom. Handles JSON commands by calling `LrDevelopController` APIs.

Both components are always upgraded together. There is no backwards compatibility between versions.

## Wire Protocol

Every message in both directions uses **4-byte big-endian uint32 length-prefix framing**:

```
[4 bytes: payload byte length as big-endian uint32][JSON payload bytes]
```

Python uses `struct.pack(">I", len)` / `struct.unpack(">I", hdr)`. Lua uses `string.char(...)` to write and byte arithmetic to read.

## MCP Server Setup

```bash
cd mcp-server
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt
python3 server.py   # test run; normally launched by Claude Desktop
```

For development and testing without Lightroom:

```bash
pip install -r requirements-dev.txt   # installs Pillow + pytest
python3 mock_lr.py                    # starts mock on localhost:54321
pytest tests/ -v                      # run all tests against the mock
```

`mock_lr.py` is a dev/test tool only. It is never deployed or referenced by Claude Desktop.

## MCP Tools Reference

| Tool | Purpose |
|---|---|
| `lr_ping` | Check the connection to the Lightroom plugin |
| `lr_get_settings` | Read all develop slider values + filename + rating |
| `lr_apply_settings` | Apply develop parameters to the selected photo |
| `lr_export_preview` | Export a JPEG thumbnail; Claude sees it inline for visual feedback |
| `lr_batch_apply_settings` | Apply develop parameters to all currently selected photos |
| `lr_auto_tone` | Run Lightroom's Auto Tone on the selected photo |
| `lr_reset` | Reset all develop settings to defaults |

### lr_export_preview

```json
{ "size": 1500 }   // optional, default 1500, max 2048 (long edge pixels)
```

Returns MCP `ImageContent` (JPEG). Typical workflow:
1. Call `lr_export_preview` — Claude sees the photo
2. Analyze tone, color, sky, etc. visually
3. Call `lr_apply_settings` with suggested changes
4. Call `lr_export_preview` again to verify

### lr_apply_settings / lr_batch_apply_settings

```json
{ "settings": { "Exposure": 0.5, "Highlights": -30 } }
```

Parameter names are case-insensitive. `lr_batch_apply_settings` uses `catalog:getTargetPhotos()` — all photos currently selected in Lightroom.

## Develop Parameter Ranges

**Tone**

| Parameter | Range | Notes |
|---|---|---|
| Exposure | -5 to 5 | |
| Contrast | -100 to 100 | |
| Highlights | -100 to 100 | |
| Shadows | -100 to 100 | |
| Whites | -100 to 100 | |
| Blacks | -100 to 100 | |
| Clarity | -100 to 100 | |
| Dehaze | -100 to 100 | |

**Color**

| Parameter | Range |
|---|---|
| Vibrance | -100 to 100 |
| Saturation | -100 to 100 |
| Temperature | 2000–50000 K |
| Tint | -150 to 150 |

**HSL** (suffix: Red/Orange/Yellow/Green/Aqua/Blue/Purple/Magenta)

| Parameter | Range |
|---|---|
| HueAdjustment* | -100 to 100 |
| SaturationAdjustment* | -100 to 100 |
| LuminanceAdjustment* | -100 to 100 |

**Detail**

| Parameter | Range |
|---|---|
| Sharpness | 0–150 |
| SharpenRadius | 0.5–3.0 |
| SharpenDetail | 0–100 |
| SharpenEdgeMasking | 0–100 |
| LuminanceSmoothing | 0–100 |
| ColorNoiseReduction | 0–100 |

**Effects**

| Parameter | Range |
|---|---|
| GrainAmount | 0–100 |
| GrainSize | 0–100 |
| PostCropVignetteAmount | -100 to 100 |
| PostCropVignetteMidpoint | 0–100 |

**Transform**

| Parameter | Range |
|---|---|
| PerspectiveVertical | -100 to 100 |
| PerspectiveHorizontal | -100 to 100 |
| PerspectiveRotate | -10 to 10 |

## Lua Plugin

Key files in `lrplugin/claude-lr-bridge.lrdevplugin/`:

- `Info.lua` — plugin manifest; registers menu items and `InitPlugin.lua`
- `InitPlugin.lua` — auto-starts the TCP server on Lightroom launch
- `Server.lua` — all TCP, framing, base64, and develop logic
- `StartServer.lua` / `StopServer.lua` — manual start/stop menu items

## Adding New Commands

1. Add a handler branch in `Server.lua`:`handleRequest()`
2. Add the tool definition in `server.py`:`list_tools()`
3. Add the dispatch case in `server.py`:`call_tool()`
4. Add the mock response in `mock_lr.py`:`_State.handle()`
5. Add a test in `tests/test_server.py`

## Key Constraints

- Parameter names in `lr_apply_settings` are case-insensitive; `Server.lua` normalises via `PARAM_INDEX`.
- `LrDevelopController` mutations must be inside `catalog:withWriteAccessDo()`.
- `photo:requestJpegThumbnail` is callback-based; `Server.lua` polls with `LrTasks.sleep(0.05)` until the callback fires (max 5s).
- The mock's `_make_jpeg` shifts hue with Temperature, so warm/cool changes are visually verifiable even without Lightroom.
```

- [ ] **Step 2: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: update CLAUDE.md with all tools, parameter ranges, and protocol docs"
```

---

## Task 9: Final verification

- [ ] **Step 1: Run full test suite**

```bash
cd mcp-server
source venv/bin/activate
pytest tests/test_server.py -v
```

Expected output:
```
tests/test_server.py::test_ping PASSED
tests/test_server.py::test_get_settings_defaults PASSED
tests/test_server.py::test_apply_settings_persists PASSED
tests/test_server.py::test_auto_tone PASSED
tests/test_server.py::test_reset_clears_settings PASSED
tests/test_server.py::test_export_preview_returns_jpeg PASSED
tests/test_server.py::test_export_preview_mcp_tool_returns_image_content PASSED
tests/test_server.py::test_batch_apply_settings_protocol PASSED
tests/test_server.py::test_batch_apply_settings_mcp_tool PASSED

9 passed in ...s
```

- [ ] **Step 2: Smoke-test mock_lr.py manually**

```bash
cd mcp-server
source venv/bin/activate
python3 mock_lr.py &
sleep 0.3
python3 -c "
import server, json
print('ping:', server.send_to_lightroom({'command':'ping'}))
server.send_to_lightroom({'command':'apply_settings','settings':{'Temperature':3000}})
r = server.send_to_lightroom({'command':'export_preview','size':100})
print('preview success:', r['success'], '| data length:', len(r.get('data','')))
print('batch:', server.send_to_lightroom({'command':'batch_apply_settings','settings':{'LuminanceSmoothing':60}}))
"
kill %1
```

Expected:
```
ping: {'success': True, 'message': 'Mock LR Bridge running'}
preview success: True | data length: <non-zero>
batch: {'success': True, 'applied': 3, 'skipped': 0, 'message': 'Applied to 3 photos, 0 skipped'}
```
