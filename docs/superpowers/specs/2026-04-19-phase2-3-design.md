# Phase 2 & 3 Design: Hardened Protocol, Preview Export, Batch, and Mock Server

## Overview

Extends the Claude Lightroom Bridge with a hardened wire protocol (length-prefix framing), a visual preview export tool, batch settings application, and a stateful mock server for testing without Lightroom.

Both the Lua plugin and Python MCP server are always versioned and deployed together. There is no backwards-compatibility requirement between the two.

---

## 1. Wire Protocol — Length-Prefix Framing

**Problem:** The current newline-delimited protocol is fragile for large payloads. A base64-encoded JPEG thumbnail (~500KB) may contain newlines or arrive in multiple TCP chunks, causing silent corruption.

**Change:** Replace newline delimiting with 4-byte big-endian uint32 length-prefix framing on both directions of the socket connection.

**Format:**
```
[4 bytes big-endian uint32: payload byte length][JSON payload bytes]
```

**Affected files:**
- `lrplugin/claude-lr-bridge.lrdevplugin/Server.lua` — update receive loop and send to read/write 4-byte header
- `mcp-server/server.py` — update `send_to_lightroom()` to pack/unpack 4-byte header with `struct.pack(">I", len)` / `struct.unpack(">I", header)`

---

## 2. New Tool: `lr_export_preview`

**Purpose:** Export a JPEG thumbnail of the currently selected photo and return it as an MCP `ImageContent` so Claude Desktop renders it inline. Enables visual feedback on develop settings.

**Typical workflow:**
1. Call `lr_export_preview` → Claude sees the photo
2. Claude analyzes tone, color, sky, etc. visually
3. Call `lr_apply_settings` with suggested parameters
4. Call `lr_export_preview` again to verify the result

**Lua implementation (`Server.lua`):**
- New `export_preview` command handler
- Uses `LrThumbnailRequest` to request a JPEG thumbnail at the specified size (default 1500px long edge, max 2048px)
- `LrThumbnailRequest` is callback-based; handler uses a boolean flag polled in a `LrTasks.yield` loop (Lua SDK pattern for blocking on async callbacks inside an `LrTasks.startAsyncTask` context)
- Base64-encodes the raw JPEG bytes using a pure-Lua base64 implementation
- Returns `{ success: true, data: "<base64>", width: N, height: N }`

**Python implementation (`server.py`):**
- New `lr_export_preview` tool with optional `size` integer parameter (default 1500, max 2048)
- On success, returns `types.ImageContent(type="image", media_type="image/jpeg", data="<base64>")`
- On error, returns `types.TextContent` with the error message

**MCP tool schema:**
```json
{
  "name": "lr_export_preview",
  "inputSchema": {
    "type": "object",
    "properties": {
      "size": {
        "type": "integer",
        "description": "Long-edge pixel size of the exported JPEG (default 1500, max 2048)"
      }
    }
  }
}
```

---

## 3. New Tool: `lr_batch_apply_settings`

**Purpose:** Apply the same develop settings to all currently selected photos at once (e.g., "denoise all selected shots").

**Lua implementation (`Server.lua`):**
- New `batch_apply_settings` command handler
- Calls `LrApplication.activeCatalog():getTargetPhotos()` to get all selected photos
- Iterates over each photo inside a single `withWriteAccessDo` transaction
- Applies the same settings dict to each photo using `LrDevelopController.setValue`
- Returns `{ success: true, applied: N, skipped: N, details: [...] }`

**Python implementation (`server.py`):**
- New `lr_batch_apply_settings` tool with the same `settings` dict schema as `lr_apply_settings`
- Returns a text summary: `"Applied to 12 photos, 0 skipped"`

**MCP tool schema:**
```json
{
  "name": "lr_batch_apply_settings",
  "inputSchema": {
    "type": "object",
    "properties": {
      "settings": {
        "type": "object",
        "description": "Key-value pairs of Lightroom develop parameters to apply to all selected photos",
        "additionalProperties": { "type": "number" }
      }
    },
    "required": ["settings"]
  }
}
```

---

## 4. Mock Server: `mock_lr.py`

**Purpose:** Development/testing tool only. Simulates the Lua TCP server so the MCP server can be tested without Lightroom open. Never deployed or referenced by Claude Desktop.

**Usage:**
```bash
python3 mock_lr.py        # starts on localhost:54321
python3 mock_lr.py --port 54322  # optional port override
```

**In-memory state:**
- `current_settings`: all develop params initialized to Lightroom defaults (Exposure=0, Contrast=0, Temperature=6500, Tint=0, Highlights=0, Shadows=0, etc.)
- `selected_photos`: list of mock filenames, default `["DSC_001.NEF", "DSC_002.NEF", "DSC_003.NEF"]`
- `rating`: int, default 0

**Command responses:**

| Command | Behaviour |
|---|---|
| `ping` | `{success: true, message: "Mock LR Bridge running"}` |
| `get_settings` | Returns `current_settings` + first filename + rating |
| `apply_settings` | Merges payload into `current_settings`, returns confirmation |
| `batch_apply_settings` | Applies to all `selected_photos`, returns count |
| `auto_tone` | Sets canned values: Exposure +0.5, Highlights -30, Shadows +20, Whites +10, Blacks -10 |
| `reset` | Resets `current_settings` to defaults |
| `export_preview` | Returns a 200×133px solid-color JPEG as base64; hue shifts with Temperature so warm/cool changes are visually verifiable |

**Dependencies:** `Pillow` (for generating the placeholder JPEG). Add to a `requirements-dev.txt`.

**Protocol:** Speaks the same 4-byte length-prefix framing as the updated Lua server.

---

## 5. CLAUDE.md Updates

Add four sections to the existing `CLAUDE.md`:

1. **Tools reference** — table of all 7 tools with purpose and key parameters
2. **Develop parameter ranges** — consolidated from `DEVELOP_PARAMS` in `Server.lua`
3. **Testing without Lightroom** — how to run `mock_lr.py`, what state it tracks
4. **Wire protocol** — 4-byte big-endian length-prefix format, both directions

---

## Files Changed / Created

| File | Change |
|---|---|
| `lrplugin/claude-lr-bridge.lrdevplugin/Server.lua` | Length-prefix framing + `export_preview` + `batch_apply_settings` handlers |
| `mcp-server/server.py` | Length-prefix framing + `lr_export_preview` + `lr_batch_apply_settings` tools |
| `mcp-server/requirements.txt` | No change (mcp already covers base64) |
| `mcp-server/mock_lr.py` | New — stateful mock TCP server (dev/test only) |
| `mcp-server/requirements-dev.txt` | New — `Pillow` for mock JPEG generation |
| `CLAUDE.md` | Updated with tools reference, parameter ranges, mock usage, wire protocol |

---

## Out of Scope

- Authentication / access control on the TCP socket
- Persistent settings history or undo beyond what Lightroom's own history provides
- Supporting multiple simultaneous Claude Desktop connections
