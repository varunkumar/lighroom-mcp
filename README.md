# Claude Lightroom Bridge

Control Lightroom Classic develop settings via Claude Desktop using MCP. Describe edits in plain English — Claude figures out the parameters and applies them instantly. With the preview tool, Claude can **see** your photo and give visual feedback on tone, color, and composition.

---

## How it works

```
You (Claude Desktop) → MCP Server (Python) → TCP Socket (port 54321) → Lua Plugin → LrDevelopController
```

The Lua plugin runs a TCP server inside Lightroom. The Python MCP server exposes tools that Claude Desktop calls. Both speak a length-prefixed JSON protocol over localhost — no internet connection required.

---

## Requirements

- **Lightroom Classic** (any recent version)
- **Python 3.9+**
- **Claude Desktop** with an active Claude subscription

---

## Setup

### Step 1 — Install the Lightroom plugin

1. Open Lightroom Classic
2. Go to **File → Plug-in Manager**
3. Click **Add** at the bottom left
4. Navigate to `lrplugin/` in this repo and select the `claude-lr-bridge.lrdevplugin` folder
5. Click **Add Plug-in**
6. Confirm the plugin status shows **Enabled**

The plugin auto-starts the bridge whenever Lightroom opens — **you do not need to start it manually each time**. The `LrInitPlugin` hook fires on every Lightroom launch and begins the file-polling loop automatically.

> **Manual control:** If `lr_ping` fails after a fresh Lightroom start (e.g. after reloading the plugin mid-session from Plug-in Manager), you can kick it manually via **File → Plug-in Extras → Start Claude LR Bridge**. This is a fallback — under normal operation Lightroom starts it for you.

---

### Step 2 — Install the MCP server

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
# Should print nothing and wait — that's correct. Ctrl-C to stop.
```

Note the **full absolute path** to both `venv/bin/python3` and `server.py`. You'll need these in the next step.

---

### Step 3 — Configure Claude Desktop

Open the Claude Desktop config file:

| Platform | Path                                                              |
| -------- | ----------------------------------------------------------------- |
| macOS    | `~/Library/Application Support/Claude/claude_desktop_config.json` |
| Windows  | `%APPDATA%\Claude\claude_desktop_config.json`                     |

Add the `lightroom` server entry. Replace the paths with your actual paths:

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

**Restart Claude Desktop** after saving. The MCP tools load at startup.

---

### Step 4 — Verify the connection

In Claude Desktop, type:

> "Ping Lightroom"

Claude will call `lr_ping`. If the plugin is running you'll see:

> ✓ Connected. Claude LR Bridge running on port 54321.

If it fails, see [Troubleshooting](#troubleshooting).

---

## Using from Claude Desktop

Once set up, talk to Claude naturally. You don't need to know any parameter names — Claude translates your intent into slider values.

### Basic editing

```
"Show me the current photo"
→ Claude calls lr_export_preview and displays the JPEG inline

"This looks underexposed, fix it"
→ Claude calls lr_apply_settings with Exposure +1.2

"Add some warmth and lift the shadows"
→ Temperature +800, Shadows +25

"It's too green — reduce the green saturation and shift the hue"
→ SaturationAdjustmentGreen -40, HueAdjustmentGreen +15

"The sky looks blown out"
→ Highlights -60, Whites -20, possibly Dehaze +15

"Make this look like a film photo"
→ Contrast +20, Fade (Blacks +15), GrainAmount 30, GrainSize 40
```

### Visual feedback workflow

The most powerful workflow: ask Claude to look at the photo, then iterate.

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
→ lr_batch_apply_settings with LuminanceSmoothing 60, ColorNoiseReduction 50

"Apply the same exposure correction to all selected shots"
→ lr_batch_apply_settings with Exposure +0.8

"Give all these photos a consistent warm grade"
→ lr_batch_apply_settings with Temperature 6800, Shadows +15, Highlights -20
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
| `lr_export_preview`       | Export a JPEG preview — Claude sees the photo inline          |
| `lr_batch_apply_settings` | Apply develop parameters to **all** currently selected photos |
| `lr_auto_tone`            | Run Lightroom's Auto Tone                                     |
| `lr_reset`                | Reset all develop settings to defaults                        |

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

**HSL** — append Red / Orange / Yellow / Green / Aqua / Blue / Purple / Magenta

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

Parameter names are **case-insensitive** — Claude can pass `exposure` or `Exposure` and the plugin normalises it.

---

## Troubleshooting

**"Cannot connect to Lightroom" / ping fails**

- Confirm Lightroom Classic is open (not Lightroom CC)
- Check the plugin is **Enabled** in File → Plug-in Manager
- Try starting the server manually: **File → Plug-in Extras → Start Claude Bridge Server** (Library module only — press `G`)
- Check no firewall is blocking localhost port 54321

**Lightroom tools not appearing in Claude Desktop**

- Confirm the paths in `claude_desktop_config.json` are absolute and correct
- Confirm you're pointing to the **venv** Python, not the system Python
- Restart Claude Desktop (not just reload — fully quit and reopen)
- Open the Claude Desktop developer console (if available) to check for MCP connection errors
- Test the server directly: `cd mcp-server && venv/bin/python3 server.py` — should start silently

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
python3 mock_lr.py                    # starts on localhost:54321
pytest tests/ -v                      # run all 9 tests
```

The mock simulates all commands, generates color-shifting JPEG previews based on Temperature, and tracks state across calls — so you can test the full Python layer without Lightroom installed.

---

## Reference

- [Lightroom Classic SDK Guide](docs/Lightroom%20Classic%20SDK%20Guide.pdf) — official Adobe SDK documentation covering all `LrDevelopController` APIs, plugin lifecycle, and Lua sandbox constraints.
