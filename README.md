# Claude Lightroom Bridge

Control Lightroom Classic develop settings via Claude Desktop using MCP.

---

## How it works

```
You (Claude Desktop) → MCP Server (Python) → TCP Socket → Lua Plugin → LrDevelopController
```

The Lua plugin runs a tiny TCP server inside Lightroom. The Python MCP server
exposes tools that Claude Desktop can call. You describe edits in plain English,
Claude figures out the right parameters, and the plugin applies them instantly.

---

## Setup

### Step 1 — Install the Lightroom plugin

1. Open Lightroom Classic
2. Go to **File → Plug-in Manager**
3. Click **Add** at the bottom left
4. Navigate to and select the `claude-lr-bridge.lrdevplugin` folder
5. Click **Add Plug-in**
6. Make sure the plugin status shows **Enabled**

The plugin auto-starts its socket server when Lightroom launches.
You can also start/stop it manually via **Library → Plug-in Extras → Start/Stop Claude Bridge Server**.

### Step 2 — Install the MCP server

```bash
cd mcp-server
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt
```

Note the full path to `server.py`, e.g. `/Users/yourname/lightroom-mcp/mcp-server/server.py`

### Step 3 — Configure Claude Desktop

Edit `~/Library/Application Support/Claude/claude_desktop_config.json`:

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

Use the full path to the venv Python, not just `python3`, so Claude Desktop
finds the right interpreter with mcp installed.

Restart Claude Desktop after saving the config.

---

## Usage examples

Once set up, just talk to Claude Desktop naturally:

- **"Make this photo look like golden hour"**
  → Claude warms the temperature, lifts shadows, reduces highlights

- **"This looks too flat, add some punch"**
  → Claude boosts contrast, clarity, and dehaze

- **"Reduce the noise, this was shot at high ISO"**
  → Claude adjusts luminance smoothing and color noise reduction

- **"What are the current develop settings?"**
  → Claude reads and reports all slider values

- **"Reset everything and start fresh"**
  → Claude resets all develop settings

---

## Available MCP tools

| Tool | What it does |
|---|---|
| `lr_apply_settings` | Apply any develop parameter values |
| `lr_get_settings` | Read current settings + metadata |
| `lr_auto_tone` | Run Lightroom's auto tone |
| `lr_reset` | Reset all develop settings |
| `lr_ping` | Check the connection is working |

---

## Develop parameters reference

**Tone:** Exposure, Contrast, Highlights, Shadows, Whites, Blacks, Clarity, Dehaze

**Color:** Vibrance, Saturation, Temperature, Tint

**HSL (each for Red/Orange/Yellow/Green/Aqua/Blue/Purple/Magenta):**
HueAdjustment*, SaturationAdjustment*, LuminanceAdjustment*

**Detail:** Sharpness, SharpenRadius, SharpenDetail, SharpenEdgeMasking,
LuminanceSmoothing, ColorNoiseReduction

**Effects:** GrainAmount, GrainSize, PostCropVignetteAmount, PostCropVignetteMidpoint

**Transform:** PerspectiveVertical, PerspectiveHorizontal, PerspectiveRotate

---

## Troubleshooting

**"Cannot connect to Lightroom"**
- Make sure Lightroom Classic is open
- Check the plugin is enabled in Plug-in Manager
- Try Library → Plug-in Extras → Start Claude Bridge Server manually

**Tools not appearing in Claude Desktop**
- Check the paths in claude_desktop_config.json are absolute paths
- Make sure you restarted Claude Desktop after editing the config
- Run `python3 server.py` directly in terminal to check for import errors

**Edits not applying**
- Make sure you are in the Develop module, or have a photo selected in Library
- The plugin switches to Develop automatically but sometimes needs a moment
