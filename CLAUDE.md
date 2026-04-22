# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Architecture

```
Claude Desktop → MCP Server (Python/stdio) → File IPC (/tmp) → Lua Plugin → LrDevelopController
```

Two components that must work in tandem:

- **`mcp-server/server.py`** — Python MCP server communicating with Claude Desktop over stdio. Writes JSON commands to `/tmp/lr_mcp_req.json` and polls for `/tmp/lr_mcp_res.json`.
- **`lrplugin/claude-lr-bridge.lrdevplugin/`** — Lightroom Classic plugin (Lua) that polls `/tmp/lr_mcp_req.json` every 50ms inside an async task. Processes commands via `LrDevelopController` APIs and writes results to `/tmp/lr_mcp_res.json`.

Both components are always upgraded together. There is no backwards compatibility between versions.

## Wire Protocol

File-based IPC using two temp files:

- **Request**: Python writes JSON to `/tmp/lr_mcp_req.json` (atomic rename from `.tmp`). Lua polls, reads, deletes it.
- **Response**: Lua writes JSON to `/tmp/lr_mcp_res.json`. Python polls and reads it.

Both files contain a single JSON object per transaction. Python times out after 10s if Lua does not respond.

> **Why not TCP?** `LrSocket` is a client-only event-driven API (connect/callbacks). It cannot bind as a server. File IPC is the correct approach for Lightroom Classic plugins.

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
python3 mock_lr.py                    # starts mock (polls /tmp/lr_mcp_req.json)
pytest tests/ -v                      # run all tests against the mock
```

`mock_lr.py` is a dev/test tool only. It is never deployed or referenced by Claude Desktop.

## MCP Tools Reference

| Tool                      | Purpose                                                            |
| ------------------------- | ------------------------------------------------------------------ |
| `lr_ping`                 | Check the connection to the Lightroom plugin                       |
| `lr_get_settings`         | Read all develop slider values + filename + rating                 |
| `lr_apply_settings`       | Apply develop parameters to the selected photo                     |
| `lr_export_preview`       | Export a JPEG thumbnail; Claude sees it inline for visual feedback |
| `lr_batch_apply_settings` | Apply develop parameters to all currently selected photos          |
| `lr_auto_tone`            | Run Lightroom's Auto Tone on the selected photo                    |
| `lr_reset`                | Reset all develop settings to defaults                             |
| `lr_crop`                 | Crop and/or straighten the selected photo                          |
| `lr_add_mask`             | Add a mask (subject, sky, gradient, brush, etc.)                   |
| `lr_lens_blur`            | Apply AI Lens Blur (depth-of-field) with bokeh shape control       |
| `lr_enhance`              | Run AI Denoise, Super Resolution, or Raw Details enhance           |

### lr_export_preview

```json
{ "size": 1500 } // optional, default 1500, max 2048 (long edge pixels)
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

| Parameter  | Range       | Notes |
| ---------- | ----------- | ----- |
| Exposure   | -5 to 5     |       |
| Contrast   | -100 to 100 |       |
| Highlights | -100 to 100 |       |
| Shadows    | -100 to 100 |       |
| Whites     | -100 to 100 |       |
| Blacks     | -100 to 100 |       |
| Clarity    | -100 to 100 |       |
| Dehaze     | -100 to 100 |       |

**Color**

| Parameter   | Range        |
| ----------- | ------------ |
| Vibrance    | -100 to 100  |
| Saturation  | -100 to 100  |
| Temperature | 2000–50000 K |
| Tint        | -150 to 150  |

**HSL** (suffix: Red/Orange/Yellow/Green/Aqua/Blue/Purple/Magenta)

| Parameter              | Range       |
| ---------------------- | ----------- |
| HueAdjustment\*        | -100 to 100 |
| SaturationAdjustment\* | -100 to 100 |
| LuminanceAdjustment\*  | -100 to 100 |

**Detail**

| Parameter           | Range   |
| ------------------- | ------- |
| Sharpness           | 0–150   |
| SharpenRadius       | 0.5–3.0 |
| SharpenDetail       | 0–100   |
| SharpenEdgeMasking  | 0–100   |
| LuminanceSmoothing  | 0–100   |
| ColorNoiseReduction | 0–100   |

**Effects**

| Parameter                | Range       |
| ------------------------ | ----------- |
| GrainAmount              | 0–100       |
| GrainSize                | 0–100       |
| PostCropVignetteAmount   | -100 to 100 |
| PostCropVignetteMidpoint | 0–100       |

**Transform**

| Parameter             | Range       |
| --------------------- | ----------- |
| PerspectiveVertical   | -100 to 100 |
| PerspectiveHorizontal | -100 to 100 |
| PerspectiveRotate     | -10 to 10   |

**Color Grading**

| Parameter              | Range       |
| ---------------------- | ----------- |
| ColorGradeBlending     | 0–100       |
| ColorGradeGlobalHue    | 0–360       |
| ColorGradeGlobalLum    | -100 to 100 |
| ColorGradeGlobalSat    | 0–100       |
| ColorGradeMidtoneHue   | 0–360       |
| ColorGradeMidtoneLum   | -100 to 100 |
| ColorGradeMidtoneSat   | 0–100       |
| ColorGradeHighlightLum | -100 to 100 |
| ColorGradeShadowLum    | -100 to 100 |

**B&W Mix** (suffix: Red/Orange/Yellow/Green/Aqua/Blue/Purple/Magenta)

| Parameter   | Range       |
| ----------- | ----------- |
| GrayMixer\* | -100 to 100 |

**Split Toning**

| Parameter                      | Range       |
| ------------------------------ | ----------- |
| SplitToningBalance             | -100 to 100 |
| SplitToningHighlightHue        | 0–360       |
| SplitToningHighlightSaturation | 0–100       |
| SplitToningShadowHue           | 0–360       |
| SplitToningShadowSaturation    | 0–100       |

**Defringe**

| Parameter              | Range |
| ---------------------- | ----- |
| DefringeGreenAmount    | 0–100 |
| DefringeGreenHueHi/Lo  | 0–100 |
| DefringePurpleAmount   | 0–100 |
| DefringePurpleHueHi/Lo | 0–100 |

### lr_lens_blur

```json
{
  "active": true,
  "amount": 50,
  "bokeh": "Circle",
  "catEye": 0,
  "highlightsBoost": 20,
  "focalRangeFromSubject": true
}
```

Valid `bokeh` values: `Circle`, `SoapBubble`, `Blade`, `Ring`, `Anamorphic`.

### lr_enhance

```json
{ "denoise": true, "denoiseAmount": 50 }
{ "superRes": true }
{ "rawDetails": true }
```

Triggers AI processing that creates a new enhanced DNG file; runs in the background after the call returns.

Key files in `lrplugin/claude-lr-bridge.lrdevplugin/`:

- `Info.lua` — plugin manifest; registers menu items and `InitPlugin.lua`
- `InitPlugin.lua` — auto-starts the bridge on Lightroom launch via `LrInitPlugin`
- `Server.lua` — file IPC polling loop, base64, JSON, and all develop logic
- `StartServer.lua` / `StopServer.lua` — manual fallback start/stop menu items

## Reference

- [Lightroom Classic SDK Guide](docs/Lightroom%20Classic%20SDK%20Guide.pdf) — official Adobe SDK documentation. Key sections: `LrDevelopController` API reference, `LrTasks` async model, plugin manifest keys, Lua sandbox restrictions.

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
- `pip install` requires the `--isolated` flag on this machine due to a system pip.conf issue: `venv/bin/python3 -m pip install --isolated <package>`
