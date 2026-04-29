# Lightroom MCP Bridge

Control Lightroom Classic develop settings from any MCP-compatible AI tool. Describe edits in plain English and the AI figures out the parameters and applies them instantly. With the preview tool, the AI can **see** your photo and give visual feedback on tone, color, and composition.

---

## How it works

```
MCP Client → MCP Server (Python/stdio) → File IPC (/tmp) → Lua Plugin → LrDevelopController
```

The Python MCP server communicates with your AI tool over stdio. It sends commands to the Lightroom plugin by writing JSON to `/tmp/lr_mcp_req.json` and polling for a response at `/tmp/lr_mcp_res.json`. The Lua plugin running inside Lightroom polls that file every 50ms, processes commands via `LrDevelopController`, and writes results back. No network connection or open ports required.

---

## Requirements

- **Lightroom Classic** (any recent version)
- **Python 3.9+**
- **Any MCP-compatible AI tool** (Claude Desktop, Cursor, Windsurf, etc.)

---

## Setup

### Step 1: Install the Lightroom plugin

1. Open Lightroom Classic
2. Go to **File → Plug-in Manager**
3. Click **Add** at the bottom left
4. Navigate to `lrplugin/` in this repo and select the `lightroom-mcp.lrdevplugin` folder
5. Click **Add Plug-in**
6. Confirm the plugin status shows **Enabled**

The plugin auto-starts the bridge whenever Lightroom opens; **you do not need to start it manually each time**. The `LrInitPlugin` hook fires on every Lightroom launch and begins the file-polling loop automatically.

> **Manual control:** If `lr_ping` fails after a fresh Lightroom start (e.g. after reloading the plugin mid-session from Plug-in Manager), you can kick it manually via **File → Plug-in Extras → Start MCP Bridge Server**. This is a fallback; under normal operation Lightroom starts it for you.

---

### Step 2: Install the MCP server

Open a terminal and run:

```bash
cd /path/to/lightroom-mcp/mcp-server
python3 -m venv venv
source venv/bin/activate          # Windows: venv\Scripts\activate
pip install -r requirements.txt
```

Verify it works:

```bash
python3 server.py
# Should print nothing and wait (that's correct). Ctrl-C to stop.
```

Note the **full absolute path** to both `venv/bin/python3` and `server.py`. You'll need these in the next step.

---

### Step 3: Configure your MCP client

Point your MCP-compatible AI tool at the server. The config format varies by tool, but the command is always the same: the venv Python running `server.py`.

**Example: Claude Desktop**

Open `~/Library/Application Support/Claude/claude_desktop_config.json` (macOS) or `%APPDATA%\Claude\claude_desktop_config.json` (Windows) and add:

```json
{
  "mcpServers": {
    "lightroom": {
      "command": "/Users/yourname/lightroom-mcp/mcp-server/venv/bin/python3",
      "args": ["/Users/yourname/lightroom-mcp/mcp-server/server.py"]
    }
  }
}
```

> **Important:** Use the full path to the **venv** Python (not the system `python3`). The venv Python has `mcp` installed; the system one doesn't.

Restart your AI tool after saving. The MCP tools load at startup.

---

### Step 4: Verify the connection

Ask your AI tool to ping Lightroom (e.g. "Ping Lightroom"). It will call `lr_ping`. If the plugin is running you'll see:

> ✓ Connected. LR MCP Bridge running.

If it fails, see [Troubleshooting](#troubleshooting).

---

## Usage

Once set up, describe what you want naturally. You don't need to know any parameter names; the AI translates your intent into slider values.

### Basic editing

```
"Show me the current photo"
→ calls lr_export_preview and displays the JPEG inline

"This looks underexposed, fix it"
→ lr_apply_settings with Exposure +1.2

"Add some warmth and lift the shadows"
→ Temperature +800, Shadows +25

"It's too green: reduce the green saturation and shift the hue"
→ SaturationAdjustmentGreen -40, HueAdjustmentGreen +15

"The sky looks blown out"
→ Highlights -60, Whites -20, possibly Dehaze +15

"Make this look like a film photo"
→ Contrast +20, Fade (Blacks +15), GrainAmount 30, GrainSize 40
```

### Visual feedback workflow

The most powerful workflow: ask the AI to look at the photo, then iterate.

```
"Show me the photo"                          → lr_export_preview
"What do you see? Any problems with the tone?"
"OK, fix the exposure and show me again"     → lr_apply_settings, lr_export_preview
"Better. The skin tones look a bit magenta"
"Adjust the red/magenta hue and show me"     → lr_apply_settings, lr_export_preview
```

### Batch editing

Select multiple photos in Lightroom, then:

```
"Denoise all selected photos"
→ lr_batch_apply_settings  LuminanceSmoothing 60, ColorNoiseReduction 50

"Apply the same exposure correction to all selected shots"
→ lr_batch_apply_settings  Exposure +0.8

"Give all these photos a consistent warm grade"
→ lr_batch_apply_settings  Temperature 6800, Shadows +15, Highlights -20
```

### Masking

AI mask types (`subject`, `sky`, `background`, `objects`, `people`, `landscape`, `luminance`, `color`, `depth`) are placed automatically. Manual types (`gradient`, `radialGradient`, `brush`) activate the tool; the user draws the mask in Lightroom.

```
"Darken the sky"
→ lr_add_mask  maskType=sky  adjustments={Exposure:-1, Highlights:-80}

"Add a subject mask and boost clarity"
→ lr_add_mask  maskType=subject  adjustments={Clarity:40, Texture:20}

"Add a gradient and I'll position it"
→ lr_add_mask  maskType=gradient  adjustments={Exposure:-1.5}
   (then drag in Lightroom to set the gradient position)

"I drew the gradient, now darken it more"
→ lr_update_mask  adjustments={Exposure:-1, Highlights:-60}
  (select the mask in LR's Masks panel first)
```

### Other commands

```
"What are the current develop settings?"     → lr_get_settings (lists all values)
"Run auto tone"                              → lr_auto_tone
"Reset everything and start from scratch"    → lr_reset
```

---

## Available tools

| Tool                      | What it does                                                  |
| ------------------------- | ------------------------------------------------------------- |
| `lr_ping`                 | Check the connection is working                               |
| `lr_get_settings`         | Read all current develop slider values + filename + rating    |
| `lr_apply_settings`       | Apply develop parameters to the selected photo                |
| `lr_export_preview`       | Export a JPEG preview; AI client sees the photo inline        |
| `lr_batch_apply_settings` | Apply develop parameters to **all** currently selected photos |
| `lr_auto_tone`            | Run Lightroom's Auto Tone                                     |
| `lr_reset`                | Reset all develop settings to defaults                        |
| `lr_crop`                 | Crop and/or straighten the selected photo                     |
| `lr_add_mask`             | Add a mask with optional local adjust sliders (subject, sky, gradient…) |
| `lr_update_mask`          | Update local adjust sliders on the currently selected mask    |
| `lr_lens_blur`            | Apply AI Lens Blur with bokeh shape control                   |
| `lr_enhance`              | Run AI Denoise, Super Resolution, or Raw Details              |

---

## Develop parameter reference

**Tone**

| Parameter  | Range       |
| ---------- | ----------- |
| Exposure   | -5 to 5     |
| Contrast   | -100 to 100 |
| Highlights | -100 to 100 |
| Shadows    | -100 to 100 |
| Whites     | -100 to 100 |
| Blacks     | -100 to 100 |
| Clarity    | -100 to 100 |
| Dehaze     | -100 to 100 |

**Color**

| Parameter   | Range        |
| ----------- | ------------ |
| Temperature | 2000–50000 K |
| Tint        | -150 to 150  |
| Vibrance    | -100 to 100  |
| Saturation  | -100 to 100  |

**HSL** (append Red / Orange / Yellow / Green / Aqua / Blue / Purple / Magenta)

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
| PerspectiveScale      | 50–150      |
| PerspectiveAspect     | -100 to 100 |
| PerspectiveX/Y        | -100 to 100 |

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

**B&W Mix** (append Red / Orange / Yellow / Green / Aqua / Blue / Purple / Magenta)

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

Parameter names are **case-insensitive**: `exposure` and `Exposure` both work; the plugin normalises them.

---

## Troubleshooting

**"Cannot connect to Lightroom" / ping fails**

- Confirm Lightroom Classic is open (not Lightroom CC)
- Check the plugin is **Enabled** in File → Plug-in Manager
- Try starting it manually: **File → Plug-in Extras → Start MCP Bridge Server** (available in any module)

**Lightroom tools not appearing in your AI tool**

- Confirm the paths in your MCP config are absolute and correct
- Confirm you're pointing to the **venv** Python, not the system Python
- Fully restart your AI tool (not just reload) after config changes
- Check your AI tool's MCP logs or developer console for connection errors
- Test the server directly: `cd mcp-server && venv/bin/python3 server.py` (should start silently)

**Edits not applying to the photo**

- A photo must be selected in Lightroom
- The plugin auto-switches to the Develop module but may need a moment
- If settings apply then revert, check Lightroom's History panel for conflicts

**`lr_export_preview` returns an error instead of an image**

- The thumbnail request can time out if Lightroom is busy building previews
- Try again after Lightroom finishes its initial preview render (progress bar in Library)

---

## Development

To test the MCP server without Lightroom open, use the included mock server:

```bash
cd mcp-server
pip install -r requirements-dev.txt   # Pillow + pytest
python3 mock_lr.py                    # polls /tmp/lr_mcp_req.json (file IPC)
pytest tests/ -v                      # run all 9 tests
```

The mock simulates all commands, generates color-shifting JPEG previews based on Temperature, and tracks state across calls, so you can test the full Python layer without Lightroom installed.

---

## Reference

- [Lightroom Classic SDK Guide](docs/Lightroom%20Classic%20SDK%20Guide.pdf): official Adobe SDK documentation covering all `LrDevelopController` APIs, plugin lifecycle, and Lua sandbox constraints.
