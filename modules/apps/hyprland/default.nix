_: {
  flake.modules.nixos.hyprland =
    { lib, pkgs, ... }:
    {
      programs.hyprland = {
        enable = true;
        withUWSM = true;
      };

      services.displayManager.defaultSession = lib.mkDefault "hyprland-uwsm";
      services.dbus.packages = [ pkgs.tumbler ];

      # The compositor asks Noctalia to lock before suspending on lid close.
      services.logind.settings.Login = {
        HandleLidSwitch = "ignore";
        HandleLidSwitchExternalPower = "ignore";
      };

      # UWSM owns the graphical session and Noctalia supplies the polkit agent.
      systemd.user.targets.nixos-fake-graphical-session.enable = false;
    };

  flake.modules.homeManager.hyprland =
    {
      config,
      lib,
      osConfig,
      pkgs,
      ...
    }:
    let
      toLua = lib.generators.toLua { };
      uwsm = lib.getExe pkgs.uwsm;
      confirmLogout = pkgs.writeShellApplication {
        name = "confirm-logout";
        runtimeInputs = [
          pkgs.libnotify
          pkgs.uwsm
        ];
        text = ''
          action="$(
            notify-send \
              --app-name=Hyprland \
              --urgency=critical \
              --expire-time=10000 \
              --action=default="Log out" \
              --wait \
              "Log out?" \
              "Left-click to end the Wayland session"
          )"

          if [[ "$action" == "default" ]]; then
            uwsm stop
          fi
        '';
      };
    in
    {
      wayland.windowManager.hyprland = {
        enable = true;
        configType = "lua";
        package = null;
        portalPackage = null;
        systemd.enable = false; # UWSM manages the session, including Noctalia.

        settings = {
          monitor = [
            {
              output = "";
              mode = "preferred";
              position = "auto";
              scale = "auto";
            }
          ];

          config = {
            general = {
              layout = "dwindle";
              gaps_in = 0;
              gaps_out = 0;
              border_size = 2;
              resize_on_border = true;
              snap.enabled = true;
            };
            dwindle = {
              smart_split = false;
              split_width_multiplier = 1.0;
              preserve_split = false;
              use_active_for_splits = true;
              force_split = 2;
            };
            decoration = {
              rounding = 0;
              blur = {
                enabled = true;
                size = 3;
                passes = 2;
                xray = false;
              };
            };
            input = {
              kb_options = "ctrl:nocaps";
              follow_mouse = 2;
              float_switch_override_focus = 0;
              focus_on_close = 2;
              touchpad = {
                disable_while_typing = true;
                natural_scroll = true;
                tap_to_click = true;
                drag_lock = true;
              };
            };
            cursor = {
              hide_on_key_press = true;
              no_warps = true;
            };
            binds = {
              workspace_back_and_forth = true;
              allow_workspace_cycles = true;
              movefocus_cycles_groupfirst = true;
            };
            misc = {
              disable_hyprland_logo = true;
              force_default_wallpaper = 0;
              # Noctalia notification actions may raise their target window.
              focus_on_activate = true;
              vrr = 3;
            };
            xwayland = {
              # XWayland windows are not scaled with the monitor; keep their
              # pixels crisp instead of filtering them.
              force_zero_scaling = true;
              use_nearest_neighbor = true;
            };
          };

          curve = [
            # HyDE's Fast preset at duration scale 1; only its used curves.
            # https://github.com/HyDE-Project/HyDE/blob/master/Configs/.local/share/hypr/lua/animations/fast.lua
            {
              _args = [
                "md3_decel"
                {
                  type = "bezier";
                  points = [
                    [
                      0.05
                      0.7
                    ]
                    [
                      0.1
                      1.0
                    ]
                  ];
                }
              ];
            }
            {
              _args = [
                "easeOutExpo"
                {
                  type = "bezier";
                  points = [
                    [
                      0.16
                      1.0
                    ]
                    [
                      0.3
                      1.0
                    ]
                  ];
                }
              ];
            }
          ];

          animation = [
            {
              leaf = "global";
              enabled = true;
              speed = 8;
              bezier = "default";
            }
            {
              leaf = "windows";
              enabled = true;
              speed = 3;
              bezier = "md3_decel";
              style = "popin 60%";
            }
            {
              leaf = "fade";
              enabled = true;
              speed = 2.5;
              bezier = "md3_decel";
            }
            {
              leaf = "workspaces";
              enabled = true;
              speed = 3.5;
              bezier = "easeOutExpo";
              style = "slide";
            }
            {
              leaf = "specialWorkspace";
              enabled = true;
              speed = 3;
              bezier = "md3_decel";
              style = "slidevert";
            }
            {
              leaf = "border";
              enabled = true;
              speed = 10;
              bezier = "default";
            }
          ];

          window_rule = [
            {
              name = "smart-border";
              match = {
                float = false;
                workspace = "w[tv1]";
              };
              border_size = 0;
            }
            {
              name = "authentication";
              match.title = "^Authentication Required$";
              float = true;
            }
            {
              name = "telegram-media";
              match = {
                class = "^org\\.telegram\\.desktop$";
                title = "(?i)^(媒体查看器|media viewer)$";
              };
              float = true;
            }
            {
              name = "firefox-picture-in-picture";
              match = {
                class = "(?i)^(firefox|org[.]mozilla[.]firefox)$";
                title = "^(Picture-in-Picture|画中画)$";
              };
              float = true;
              pin = true;
              keep_aspect_ratio = true;
              persistent_size = true;
            }
            {
              # Feishu's sharing preview and its in-call window both report
              # class Meeting with no distinguishing title, so both float;
              # the share preview otherwise takes a tile while presenting.
              name = "feishu-meeting";
              match.class = "^Meeting$";
              float = true;
            }
            {
              name = "meeting-idle-inhibit";
              match.class = "(?i)^(wemeet(app)?|com[.]tencent[.]wemeet)$";
              idle_inhibit = "focus";
            }
            {
              name = "noctalia-settings";
              match.class = "^dev\\.noctalia\\.Noctalia$";
              float = true;
              size = [
                1080
                920
              ];
              center = true;
            }
            {
              name = "1password-capture";
              match.class = "(?i).*1password.*";
              no_screen_share = true;
            }
            {
              name = "gaming-vrr";
              match.class = "^(steam|steam_app_.*|gamescope)$";
              content = "game";
              idle_inhibit = "fullscreen";
            }
            {
              name = "video-vrr";
              match.class = "^mpv$";
              content = "video";
              idle_inhibit = "fullscreen";
            }
            {
              # Clawd's overlays — the pet itself, its session HUD, quota ring,
              # permission bubbles and the click surface — are frameless
              # always-on-top windows that draw their own pixels and place
              # themselves; the settings, dashboard and welcome windows are
              # framed dialogs, and their titles are localized. So this matches
              # the overlay titles (every frameless page falls back to the app
              # name, which is "clawd-on-desk") rather than the class.
              #
              # decorate: the composer's border, shadow and rounding belong to a
              # window that the user manages; the pet is a 150 px sprite on a
              # transparent window, so the border draws a rectangle around it.
              # no_anim: applyPetWindowBounds() moves the pet window every frame
              # while it roams, and the configured move/resize animation would
              # make it trail the position it is being told to take.
              # no_blur: the window is transparent everywhere the sprite is not,
              # so blur would show as a halo behind the pet.
              #
              # pin: the app asks the window manager to keep the pet on every
              # workspace (#979) by setting _NET_WM_STATE_STICKY itself, which
              # Hyprland does not act on; the pin rule is the compositor-side
              # equivalent, and it carries the overlays that belong to the pet
              # (HUD, quota ring, bubbles) along with it. It only applies to
              # floating windows, which is what the float above is for.
              name = "clawd-overlays";
              match.title = "^(Clawd|clawd-on-desk|Session HUD|Quota Ring|Choose Clawd activity area|Animation Preview)$";
              float = true;
              pin = true;
              decorate = false;
              no_shadow = true;
              no_blur = true;
              no_anim = true;
              no_initial_focus = true;
            }
          ];

          # https://docs.noctalia.dev/noctalia/compositor-settings/hyprland/
          layer_rule = [
            {
              name = "noctalia";
              match.namespace = "^noctalia-(bar-.+|notification|dock|panel|attached-panel|osd|window-switcher)$";
              no_anim = true;
              ignore_alpha = 0.5;
              blur = true;
              blur_popups = true;
            }
            {
              name = "noctalia-notification-privacy";
              match.namespace = "^noctalia-notification$";
              no_screen_share = true;
            }
          ];

          gesture = {
            fingers = 3;
            direction = "horizontal";
            action = "workspace";
          };
          on._args = [
            "hyprland.start"
            (lib.generators.mkLuaInline ''
              function()
                hl.exec_cmd(${toLua "${uwsm} app -- 1password --silent"})
              end
            '')
          ];
        };

        extraConfig =
          builtins.replaceStrings
            [ "@terminal@" "@ipc@" "@logout@" "@reload@" ]
            [
              (toLua "${lib.getExe pkgs.ghostty} +new-window")
              (toLua "${lib.getExe osConfig.programs.noctalia.package} msg ")
              (toLua (lib.getExe confirmLogout))
              (toLua "${lib.getExe' osConfig.programs.hyprland.package "hyprctl"} reload config-only")
            ]
            (builtins.readFile ./bindings.lua);
      };

      # Noctalia owns wallpaper rendering; a second wallpaper daemon would
      # compete with its per-monitor wallpaper settings.
      stylix.targets.hyprland.hyprpaper.enable = false;
      xdg.configFile."uwsm/env".source =
        "${config.home.sessionVariablesPackage}/etc/profile.d/hm-session-vars.sh";
      xdg.configFile."hypr/xdph.conf".text = ''
        screencopy {
          max_fps = 60
        }
      '';

      home = {
        packages = with pkgs; [
          atril
          brightnessctl
          ristretto
          seahorse
          tumbler
          wl-clipboard
          xarchiver
        ];
        sessionVariables = {
          NIXOS_OZONE_WL = "1";
          ELECTRON_OZONE_PLATFORM_HINT = "auto";
        };
      };

      programs.gpg.enable = true;
      services.gpg-agent = {
        enable = true;
        pinentry.package = pkgs.pinentry-gnome3;
      };
    };
}
