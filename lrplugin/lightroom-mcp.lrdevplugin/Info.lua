return {
    LrSdkVersion = 10.0,
    LrToolkitIdentifier = "dev.varunkumar.lightroom.mcp",
    LrPluginName = "Lightroom MCP Bridge",
    LrPluginInfoUrl = "https://github.com/varunkumar/lighroom-mcp",

    VERSION = { major = 1, minor = 0, revision = 3 },

    LrExportMenuItems = {
        {
            title = "Start MCP Bridge Server",
            file = "StartServer.lua",
        },
        {
            title = "Stop MCP Bridge Server",
            file = "StopServer.lua",
        },
    },

    LrInitPlugin = "InitPlugin.lua",
}
