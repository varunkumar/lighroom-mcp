# lr_update_mask Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a new `lr_update_mask` MCP tool that applies local develop slider adjustments to whichever mask is currently selected in Lightroom's Masks panel.

**Architecture:** The currently-selected mask in LR's Masks panel is the "active" local adjustment context for `LrDevelopController`. Calling `LrDevelopController.setValue("local_Exposure", value)` (etc.) targets that active mask directly — the same mechanism already proven by `lr_add_mask`. No mask creation or selection logic is needed; the user selects the mask in LR, then calls this tool.

**Tech Stack:** Lua (LrDevelopController), Python (MCP/FastMCP), JSON file IPC over `/tmp`

---

## File Map

| File | Change |
|------|--------|
| `lrplugin/claude-lr-bridge.lrdevplugin/Server.lua` | Add `updateMask()` function + `"update_mask"` dispatch branch |
| `lrplugin/claude-lr-bridge.lrdevplugin/Info.lua` | Bump version to 1.5.0 |
| `mcp-server/server.py` | Add `lr_update_mask` tool definition + `call_tool` dispatch |
| `mcp-server/mock_lr.py` | Add `"update_mask"` command handler |
| `mcp-server/tests/test_server.py` | Add 3 tests for `lr_update_mask` |
| `CLAUDE.md` | Document `lr_update_mask` under MCP Tools Reference |
| `README.md` | Add `lr_update_mask` to tools table + Masking section |

---

### Task 1: Mock + tests (TDD first)

**Files:**
- Modify: `mcp-server/mock_lr.py`
- Modify: `mcp-server/tests/test_server.py`

- [ ] **Step 1: Add `update_mask` handler to mock**

In `mcp-server/mock_lr.py`, add this block inside `_State.handle()` right after the `add_mask` block (before the `export_preview` block):

```python
            if cmd == "update_mask":
                adjustments = req.get("adjustments") or {}
                if not adjustments:
                    return {"success": False, "error": "No adjustments provided"}
                msg = "Mask updated with adjustments: " + ", ".join(
                    f"{k}={v}" for k, v in adjustments.items()
                )
                return {"success": True, "message": msg}
```

- [ ] **Step 2: Write failing tests**

Append to `mcp-server/tests/test_server.py`:

```python
# ── lr_update_mask ────────────────────────────────────────────────────────────

def test_update_mask_protocol(mock_lr):
    import server
    result = server.send_to_lightroom({
        "command": "update_mask",
        "adjustments": {"Exposure": 1.0, "Saturation": -20},
    })
    assert result["success"] is True
    assert "Exposure" in result["message"]


def test_update_mask_no_adjustments(mock_lr):
    import server
    result = server.send_to_lightroom({
        "command": "update_mask",
        "adjustments": {},
    })
    assert result["success"] is False
    assert "adjustments" in result["error"].lower()


def test_update_mask_mcp_tool(mock_lr):
    import json
    import server
    from mcp import types
    contents = asyncio.run(server.call_tool(
        "lr_update_mask",
        {"adjustments": {"Highlights": -50, "Clarity": 20}},
    ))
    assert len(contents) == 1
    assert isinstance(contents[0], types.TextContent)
    data = json.loads(contents[0].text)
    assert data["success"] is True
```

- [ ] **Step 3: Run tests — expect 3 failures**

```bash
cd /Users/varunkumar/projects/lightroom-mcp/mcp-server && pytest tests/test_server.py::test_update_mask_protocol tests/test_server.py::test_update_mask_no_adjustments tests/test_server.py::test_update_mask_mcp_tool -v
```

Expected: all 3 FAIL (tool not defined yet, `update_mask` unknown command)

---

### Task 2: MCP server — tool definition + dispatch

**Files:**
- Modify: `mcp-server/server.py`

- [ ] **Step 1: Add `lr_update_mask` tool definition**

In `server.py`, inside `list_tools()`, add this after the `lr_add_mask` tool block (before the closing `]`):

```python
        types.Tool(
            name="lr_update_mask",
            description=(
                "Update the local develop sliders on the mask that is currently selected "
                "in Lightroom's Masks panel. Select the mask in LR first, then call this "
                "tool with the slider values to apply. Supported adjustments: Exposure, "
                "Contrast, Highlights, Shadows, Whites, Blacks, Clarity, Texture, Dehaze, "
                "Vibrance, Saturation, Temperature, Tint, Sharpness, LuminanceNoise, "
                "ColorNoise, MoireFilter, Defringe, ToningHue, ToningSaturation."
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
```

- [ ] **Step 2: Add dispatch case in `call_tool`**

In `server.py`, inside `call_tool()`, add after the `lr_add_mask` block:

```python
    elif name == "lr_update_mask":
        adjustments = arguments.get("adjustments", {})
        if not adjustments:
            result = {"success": False, "error": "No adjustments provided"}
        else:
            result = send_to_lightroom({
                "command": "update_mask",
                "adjustments": adjustments,
            })
```

- [ ] **Step 3: Run the MCP tool test — expect 1 pass, 2 still fail**

```bash
cd /Users/varunkumar/projects/lightroom-mcp/mcp-server && pytest tests/test_server.py::test_update_mask_protocol tests/test_server.py::test_update_mask_no_adjustments tests/test_server.py::test_update_mask_mcp_tool -v
```

Expected: `test_update_mask_protocol` PASS, `test_update_mask_no_adjustments` PASS, `test_update_mask_mcp_tool` PASS (all pass once mock+server are both in place)

---

### Task 3: Lua plugin — `updateMask` handler

**Files:**
- Modify: `lrplugin/claude-lr-bridge.lrdevplugin/Server.lua`
- Modify: `lrplugin/claude-lr-bridge.lrdevplugin/Info.lua`

- [ ] **Step 1: Add `updateMask` function in Server.lua**

Add this function immediately after the closing `end` of `addMask` (around line 588), before the `BOKEH_TYPES` block:

```lua
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
```

- [ ] **Step 2: Add `"update_mask"` dispatch branch in `handleRequest`**

In `Server.lua`, inside `handleRequest()`, add after the `"add_mask"` branch:

```lua
    elseif cmd == "update_mask" then
        local s, msg = updateMask(req.adjustments)
        response = { success = s, message = msg }
```

- [ ] **Step 3: Bump version in Server.lua**

Change:
```lua
local VERSION = "1.4.2"  -- keep in sync with Info.lua VERSION
```
To:
```lua
local VERSION = "1.5.0"  -- keep in sync with Info.lua VERSION
```

- [ ] **Step 4: Bump version in Info.lua**

Change:
```lua
VERSION = { major = 1, minor = 4, revision = 2 },
```
To:
```lua
VERSION = { major = 1, minor = 5, revision = 0 },
```

---

### Task 4: Run all tests + commit

**Files:** none (verification + commit)

- [ ] **Step 1: Run full test suite**

```bash
cd /Users/varunkumar/projects/lightroom-mcp/mcp-server && pytest tests/ -v
```

Expected: all 3 new `update_mask` tests PASS, existing tests unchanged.

- [ ] **Step 2: Update CLAUDE.md tools table**

In `CLAUDE.md`, add `lr_update_mask` to the MCP Tools Reference table:

```markdown
| `lr_update_mask`          | Update local adjust sliders on the currently selected mask     |
```

Add a `### lr_update_mask` section after `### lr_add_mask`:

```markdown
### lr_update_mask

```json
{ "adjustments": { "Exposure": 0.5, "Highlights": -30 } }
```

Applies local develop sliders to whichever mask is currently selected in LR's Masks panel. Select the target mask in LR first, then call this tool. Same parameter names and ranges as the `adjustments` field in `lr_add_mask`.

Implemented via `LrDevelopController.setValue("local_*")` on the active mask.
```

- [ ] **Step 3: Update README.md tools table**

In `README.md`, add to the tools table:

```markdown
| `lr_update_mask`          | Update local adjust sliders on the currently selected mask     |
```

Add to the Masking section:

```markdown
"I drew the gradient, now darken it more"
→ lr_update_mask  adjustments={Exposure:-1, Highlights:-60}
  (select the mask in LR's Masks panel first)
```

- [ ] **Step 4: Commit**

```bash
git add lrplugin/claude-lr-bridge.lrdevplugin/Server.lua \
        lrplugin/claude-lr-bridge.lrdevplugin/Info.lua \
        mcp-server/server.py \
        mcp-server/mock_lr.py \
        mcp-server/tests/test_server.py \
        CLAUDE.md README.md
git commit -m "feat: add lr_update_mask — apply sliders to active mask (v1.5.0)"
```

---

### Task 5: Live test in Lightroom

- [ ] **Step 1:** Reload plugin in LR Plugin Manager
- [ ] **Step 2:** Confirm v1.5.0 in log: `tail -3 ~/Library/Logs/Adobe/Lightroom/LrClassicLogs/ClaudeLRBridge.log`
- [ ] **Step 3:** In LR Develop module, click any existing mask in the Masks panel to make it active
- [ ] **Step 4:** Call `lr_update_mask` with strong values and verify the image changes:
  ```json
  { "adjustments": { "Exposure": -2, "Saturation": -100 } }
  ```
- [ ] **Step 5:** Confirm log shows `Mask updated: Exposure, Saturation`
