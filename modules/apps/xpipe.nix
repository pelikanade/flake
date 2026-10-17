_: {
  flake.modules.homeManager.xpipe =
    { pkgs, ... }:
    let
      preferences = {
        disableHardwareAcceleration = false;
        preferMonochromeIcons = false;
        useExternalNetcatForProxies = false;
        pinLocalMachineOnStartup = false;
        enableHttpApi = false;
        enableMcpServer = false;
        mcpAdditionalContext = null;
        performanceMode = false;
        limitedTouchscreenMode = false;
        theme = "nordDark";
        useSystemFont = true;
        uiScale = null;
        saveWindowLocation = true;
        preferTerminalTabs = false;
        terminalType = "app.ghostty";
        rdpClientType.type = "freeRdp";
        windowOpacity = 1.0;
        customTerminalCommand = null;
        clearTerminalOnInit = true;
        disableCertutilUse = false;
        useLocalFallbackShell = false;
        localShellDialect = "bash";
        focusWindowOnNotifications = true;
        vncClient.type = "integratedXPipeVncClient";
        spiceClient.type = "remoteViewer";
        passwordManager = {
          type = "onePassword";
          account = null;
          keyStrategy.type = "agent";
        };
        terminalInitScript = null;
        httpProxy = null;
        terminalProxy = null;
        terminalMultiplexer = null;
        terminalAlwaysPauseOnExit = true;
        terminalSplitStrategy = "balanced";
        terminalPrompt = null;
        startupBehaviour = "app.startGui";
        enableGitStorage = true;
        storageGitRemote = "https://github.com/AsterisMono/xpipe-vault";
        syncMode = "instant";
        closeBehaviour = "app.quit";
        externalEditor = "app.neovim";
        customEditorCommand = "";
        customEditorCommandInTerminal = false;
        automaticallyCheckForUpdates = false;
        enableTerminalLogging = false;
        enableTerminalStartupBell = false;
        checkForSecurityUpdates = false;
        disableHttpsTlsCheck = false;
        condenseConnectionDisplay = false;
        showChildrenConnectionsInParentCategory = true;
        hibernateBehaviour = null;
        openConnectionSearchWindowOnConnectionCreation = true;
        downloadsDirectory = null;
        developerMode = false;
        developerDisableUpdateVersionCheck = false;
        developerForceSshTty = false;
        developerDisableSshTunnelGateways = false;
        developerPrintInitFiles = false;
        developerShowSensitiveCommands = false;
        disableSshPinCaching = false;
        language = "zh-Hans";
        sshAgentSocket = null;
        requireDoubleClickForConnections = false;
        editFilesWithDoubleClick = false;
        enableFileBrowserTerminalDocking = true;
        enableConnectionHubTerminalDocking = true;
        censorMode = false;
        sshVerboseOutput = false;
        disableApiAuthentication = false;
        allowExternalApiRequests = false;
        gitUsername = null;
        gitPassword.type = "none";
        gitVaultIdentityStrategy.type = "none";
        syncToPlainDirectory = false;
        x11WslInstance = "";
      };
    in
    {
      home.packages = [
        pkgs.unstable.xpipe
        pkgs.unstable.socat
      ];

      home.file.".xpipe/settings/preferences.json".text = builtins.toJSON preferences;
    };
}
