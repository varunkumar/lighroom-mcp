return {
    LrSdkVersion = 10.0,
    LrToolkitIdentifier = "com.claude.lightroom.bridge",
    LrPluginName = "Claude LR Bridge",
    LrPluginInfoUrl = "",

    VERSION = { major = 1, minor = 0, revision = 0 },

    LrLibraryMenuItems = {
        {
            title = "Start Claude Bridge Server",
            file = "StartServer.lua",
        },
        {
            title = "Stop Claude Bridge Server",
            file = "StopServer.lua",
        },
    },

    LrInitPlugin = "InitPlugin.lua",
}
