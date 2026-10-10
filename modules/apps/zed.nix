{ inputs, ... }: {
  flake-file.inputs.zed-glassy-nord = {
    url = "github:matt-gilb/zed_glassy-nord";
    flake = false;
  };

  flake.modules.homeManager.zed =
    { pkgs, lib, ... }:
    let
      typescriptSettings = {
        code_actions_on_format = {
          "source.addMissingImports.ts" = true;
          "source.fixAll.eslint" = true;
          "source.fixAll.ts" = true;
          "source.removeUnusedImports.ts" = true;
        };
        language_servers = [
          "typescript-language-server"
          "!vtsls"
          "..."
        ];
      };

      glassyNord = builtins.fromJSON (
        builtins.readFile (inputs.zed-glassy-nord + "/themes/glassy_nord.json")
      );

      # Zed draws drop shadows and fade gradients assuming each surface has an
      # opaque base. The theme leaves its editor/panel/terminal backgrounds
      # fully transparent, so those effects render as hard-edged dark patches
      # over the blurred compositor background. Give every fully transparent
      # `*.background` a faint tint of the variant's base colour so they blend.
      tintAlpha = "40";

      tintTheme =
        theme:
        let
          base = builtins.substring 0 7 theme.style.background;
        in
        theme
        // {
          style = builtins.mapAttrs (
            name: value:
            if
              (name == "background" || lib.hasSuffix ".background" name)
              && lib.isString value
              && builtins.stringLength value == 9
              && lib.hasSuffix "00" value
            then
              "${base}${tintAlpha}"
            else
              value
          ) theme.style;
        };

      tintedTheme = glassyNord // {
        themes = map tintTheme glassyNord.themes;
      };
    in
    {
      programs.zed-editor = {
        enable = true;
        package = pkgs.unstable.zed-editor;

        extensions = [
          "astro"
          "html"
          "just"
          "nix"
          "svelte"
          "nvim-nightfox"
          "biome"
          "terraform"
          "nordic-theme"
          "nord"
        ];

        themes.glassy_nord = builtins.toJSON tintedTheme;

        userSettings = {
          agent_servers = {
            qwen-code.type = "registry";
            codex-acp = {
              default_config_options = {
                mode = "agent";
                reasoning_effort = "high";
              };
              type = "registry";
            };
          };

          agent = {
            tool_permissions.tools.terminal.default = "allow";
            default_model = {
              provider = "openrouter";
              model = "anthropic/claude-fable-5";
              enable_thinking = true;
            };
            dock = "right";
            favorite_models = [ ];
            model_parameters = [ ];
          };

          indent_guides = {
            enabled = true;
            coloring = "indent_aware";
          };
          cli_default_open_behavior = "new_window";
          buffer_font_family = "FiraCode Nerd Font";
          # Use static CJK fonts; non-400 weights can break Linux fallbacks.
          # https://github.com/zed-industries/zed/issues/60155
          buffer_font_fallbacks = [ "Source Han Sans SC" ];
          buffer_font_size = 15.0;
          buffer_font_weight = 400;
          ui_font_size = 16.0;
          ui_font_fallbacks = [ "Source Han Sans SC" ];
          ui_font_weight = 400;
          colorize_brackets = true;
          cursor_blink = false;
          diagnostics.inline.enabled = true;
          soft_wrap = "editor_width";
          git.inline_blame.enabled = false;

          languages = {
            JavaScript = typescriptSettings;
            Nix = {
              format_on_save = "on";
              formatter.external.command = "nixfmt";
              language_servers = [
                "nixd"
                "!nil"
                "..."
              ];
            };
            TSX = typescriptSettings;
            TypeScript = typescriptSettings;
          };

          load_direnv = "direct";
          lsp = {
            json-language-server.settings.json.schemas = [
              {
                fileMatch = [ "package.json" ];
                url = "https://www.schemastore.org/package";
              }
            ];
            yaml-language-server.settings.yaml = {
              schemaStore.enable = true;
              completion = true;
            };
            biome.settings.require_config_file = true;
          };

          project_panel.dock = "left";
          rounded_selection = false;
          status_bar = {
            active_language_button = false;
            cursor_position_button = false;
          };
          tab_bar = {
            show_nav_history_buttons = false;
            show_tab_bar_buttons = false;
          };
          tabs = {
            git_status = true;
            show_diagnostics = "errors";
          };
          telemetry = {
            diagnostics = false;
            metrics = false;
          };
          terminal = {
            blinking = "off";
            cursor_shape = "bar";
            shell.program = lib.getExe pkgs.fish;
            scrollbar.show = "never";
          };
          theme = {
            dark = "Glassy Nord Dark";
            light = "Glassy Nord Light";
            mode = "dark";
          };
          title_bar.show_user_picture = false;
          toolbar.quick_actions = false;
          ui_font_family = "FiraCode Nerd Font";
          vim.use_system_clipboard = "on_yank";
          vim_mode = true;
          which_key.enabled = true;
        };

        userKeymaps = [
          {
            context = "Dock";
            bindings = {
              "ctrl-w h" = "workspace::ActivatePaneLeft";
              "ctrl-w j" = "workspace::ActivatePaneDown";
              "ctrl-w k" = "workspace::ActivatePaneUp";
              "ctrl-w l" = "workspace::ActivatePaneRight";
              "ctrl-w ctrl-h" = "pane::ActivatePreviousItem";
              "ctrl-w ctrl-l" = "pane::ActivateNextItem";
              "ctrl-t" = "workspace::NewTerminal";
            };
          }
          {
            context = "VimControl && !menu";
            bindings = {
              "ctrl-h" = "pane::ActivatePreviousItem";
              "ctrl-l" = "pane::ActivateNextItem";
              "ctrl-p" = "file_finder::Toggle";
              "ctrl-s" = "workspace::Save";
              "ctrl-x" = "pane::CloseActiveItem";
            };
          }
          {
            context = "VimControl && (vim_mode == normal || vim_mode == visual)";
            bindings = {
              s = "vim::PushSneak";
              "shift-s" = "vim::PushSneakBackward";
            };
          }
          {
            context = "VimControl && vim_mode == normal";
            bindings = {
              "space b l" = "pane::CloseItemsToTheLeft";
              "space b r" = "pane::CloseItemsToTheRight";
              "space b o" = "pane::CloseOtherItems";
              "space f f" = "pane::RevealInProjectPanel";
              "space r n" = "editor::Rename";
              "] d" = "editor::GoToDiagnostic";
              "[ d" = "editor::GoToPreviousDiagnostic";
            };
          }
          {
            context = "Workspace && !Dock";
            bindings = {
              "ctrl-h" = "pane::ActivatePreviousItem";
              "ctrl-l" = "pane::ActivateNextItem";
              "ctrl-p" = "file_finder::Toggle";
              "ctrl-shift-t" = "pane::ReopenClosedItem";
              "ctrl-x" = "pane::CloseActiveItem";
            };
          }
        ];
      };
    };
}
