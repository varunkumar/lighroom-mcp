# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Architecture

```
Claude Desktop → MCP Server (Python/stdio) → TCP Socket (port 54321) → Lua Plugin → LrDevelopController
```

Two components that must work in tandem:

- **`mcp-server/server.py`** — Python MCP server communicating with Claude Desktop over stdio. Sends JSON commands to the Lua plugin over a TCP socket and returns results as MCP tool responses.
- **`lrplugin/claude-lr-bridge.lrdevplugin/`** — Lightroom Classic plugin (Lua) that runs a TCP server on port 54321 inside Lightroom. Handles JSON commands by calling `LrDevelopController` APIs.

The protocol is newline-delimited JSON: each message is one JSON object terminated by `\n`.

## MCP Server Setup

```bash
cd mcp-server
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt
python3 server.py   # test run; normally launched by Claude Desktop
```

The only dependency is `mcp>=1.0.0`. The server is launched by Claude Desktop via `claude_desktop_config.json` — use absolute paths to the venv Python and `server.py`.

## Lua Plugin

The plugin lives in `lrplugin/claude-lr-bridge.lrdevplugin/`. Key files:

- `Info.lua` — plugin manifest; registers menu items and `InitPlugin.lua` as the entry point
- `InitPlugin.lua` — auto-starts the TCP server on Lightroom launch
- `Server.lua` — all TCP and develop logic; the `DEVELOP_PARAMS` list defines every parameter accessible via `LrDevelopController`
- `StartServer.lua` / `StopServer.lua` — manual start/stop menu items

To test the plugin without Claude Desktop, run the MCP server manually and send raw JSON over TCP:
```bash
echo '{"command":"ping"}' | nc localhost 54321
```

## Adding New Commands

1. Add a handler branch in `Server.lua`:`handleRequest()`
2. Add the corresponding tool definition in `server.py`:`list_tools()`
3. Add the dispatch case in `server.py`:`call_tool()`

## Key Constraints

- Parameter names in `lr_apply_settings` are case-insensitive on the Python side; `Server.lua` normalises them via `PARAM_INDEX` (lowercase → canonical name).
- `LrDevelopController` calls must happen inside `catalog:withWriteAccessDo()` for mutations; reads (`getValue`) do not require write access.
- The Lua server runs a blocking loop with a 1-second `accept` timeout; each client connection is handled in an `LrTasks.startAsyncTask` to avoid blocking the main loop.
