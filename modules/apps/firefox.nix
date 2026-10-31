_: {
  flake.modules.homeManager.firefox =
    {
      pkgs,
      lib,
      ...
    }:
    {
      programs.firefox = {
        enable = true;
        package = pkgs.unstable.firefox;
        policies = {
          ExtensionSettings =
            lib.mapAttrs
              (
                _: value:
                {
                  installation_mode = "force_installed";
                  default_area = "menupanel";
                }
                // value
              )
              {
                "uBlock0@raymondhill.net" = {
                  install_url = "https://addons.mozilla.org/firefox/downloads/latest/ublock-origin/latest.xpi";
                };
                "{3c078156-979c-498b-8990-85f7987dd929}" = {
                  install_url = "https://addons.mozilla.org/firefox/downloads/latest/sidebery/latest.xpi";
                  default_area = "navbar";
                };
                "sponsorBlocker@ajay.app" = {
                  install_url = "https://addons.mozilla.org/firefox/downloads/latest/sponsorblock/latest.xpi";
                };
                "jid1-MnnxcxisBPnSXQ@jetpack" = {
                  install_url = "https://addons.mozilla.org/firefox/downloads/latest/privacy-badger17/latest.xpi";
                };
                "{d7742d87-e61d-4b78-b8a1-b469842139fa}" = {
                  install_url = "https://addons.mozilla.org/firefox/downloads/latest/vimium-ff/latest.xpi";
                };
                "queryamoid@kaply.com" = {
                  install_url = "https://github.com/mkaply/queryamoid/releases/download/v0.1/query_amo_addon_id-0.1-fx.xpi";
                };
                "{a4c4eda4-fb84-4a84-b4a1-f7c1cbf2a1ad}" = {
                  install_url = "https://addons.mozilla.org/firefox/downloads/latest/refined-github-/latest.xpi";
                };
                "jid1-BoFifL9Vbdl2zQ@jetpack" = {
                  install_url = "https://addons.mozilla.org/firefox/downloads/latest/decentraleyes/latest.xpi";
                };
                "{74145f27-f039-47ce-a470-a662b129930a}" = {
                  install_url = "https://addons.mozilla.org/firefox/downloads/latest/clearurls/latest.xpi";
                };
                "chrome-mask@overengineer.dev" = {
                  install_url = "https://addons.mozilla.org/firefox/downloads/latest/chrome-mask/latest.xpi";
                };
                "redirect-nix-wiki@undesided.me" = {
                  install_url = "https://addons.mozilla.org/firefox/downloads/latest/redirectnixwiki/latest.xpi";
                };
                "{eceab40b-230a-4560-98ed-185ad010633f}" = {
                  install_url = "https://addons.mozilla.org/firefox/downloads/latest/nixos-packages-search-engine/latest.xpi";
                };
                "{39ba6e88-6981-4e1f-9c68-591c9965633b}" = {
                  install_url = "https://addons.mozilla.org/firefox/downloads/latest/nixos-options-search-engine/latest.xpi";
                };
                "Tab-Session-Manager@sienori" = {
                  install_url = "https://addons.mozilla.org/firefox/downloads/latest/tab-session-manager/latest.xpi";
                };
                "{d634138d-c276-4fc8-924b-40a0ea21d284}" = {
                  install_url = "https://addons.mozilla.org/firefox/downloads/latest/1password-x-password-manager/latest.xpi";
                };
              };
          DisplayBookmarksToolbar = "never";
          DisablePocket = true;
          OfferToSaveLogins = false;
          PasswordManagerEnabled = false;
          Homepage.StartPage = "previous-session";
          Preferences = {
            "toolkit.legacyUserProfileCustomizations.stylesheets" = true;
            "browser.newtabpage.activity-stream.feeds.topsites" = false;
            "browser.ctrlTab.sortByRecentlyUsed" = true;
            "media.ffmpeg.vaapi.enabled" = true;
            "gfx.webrender.all" = true;
            "media.hardware-video-decoding.force-enabled" = true;
            "browser.aboutaddons.novaThemesPickerEnabled" = false;
            "browser.newtabpage.activity-stream.nova.enabled" = false;
            "browser.nova.enabled" = false;
            "pdfjs.enableNova" = false;
            "sidebar.revamp" = false;
          };
          RequestedLocales = "zh-cn,zh,zh-tw,zh-hk,en-us,en";
        };
        profiles.default = {
          isDefault = true;
          name = "Brunette";

          # Sidebery draws the tabs in the sidebar, so Firefox's own tab strip and
          # the header above the sidebar go away; the chrome sheet carries nothing
          # else.
          userChrome = ''
            #TabsToolbar {
              display: none;
            }
            #sidebar-header {
              display: none;
            }
            #sidebar-button {
              display: none;
            }
            #back-button {
              padding-inline-start: var(--toolbar-padding-inline);
            }
            #sidebar-box {
              padding-inline-start: 0 !important;
            }
          '';
        };
      };
    };
}
