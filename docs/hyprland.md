# Hyprland desktop

The workstation role and `stylix-test` use the Hyprland package from the locked NixOS release. Home Manager generates its Lua configuration from [the desktop aspect](../modules/apps/hyprland/default.nix) and [bindings](../modules/apps/hyprland/bindings.lua). UWSM manages the session; the display-manager entry is **Hyprland (uwsm-managed)**.

Bindings use the familiar Sway window controls from before commit `b0903cf`, with the later Noctalia adaptations. Hyprland's [dwindle layout](https://wiki.hypr.land/0.55.0/Configuring/Layouts/Dwindle-Layout/) replaces Sway's automatic splits: a wider focused window splits left/right, a taller one splits top/bottom, and existing splits can change direction as their geometry changes (`preserve_split = false`). New windows open to the right or below. Stylix supplies Rose Pine Moon colours, fonts and the cursor; Noctalia owns the wallpaper and shell. Window corners are 8 px, borders 2 px, outer gaps 12 px and shared inner gaps 12 px. Shadows are enabled with Hyprland's default geometry and the Stylix theme colour. Transparent windows and Noctalia surfaces use background blur.

Animations follow [HyDE's Fast preset](https://github.com/HyDE-Project/HyDE/blob/master/Configs/.local/share/hypr/lua/animations/fast.lua) at its default duration scale of 1. Windows use `popin`: opening scales from 60% to 100% and closing from 100% to 60%, over 300 ms. Window movement/resizing also takes 300 ms; fades take 250 ms. These effects use the custom `md3_decel` Bézier curve with control points `(0.05, 0.7)` and `(0.1, 1)`, without spring bounce. Ordinary workspaces slide horizontally over 350 ms using `easeOutExpo`, with control points `(0.16, 1)` and `(0.3, 1)`; the special scratchpad slides vertically over 300 ms using `md3_decel`. Border colour changes take 1 second, gradient border rotation remains disabled, and effects not specified by the preset retain the built-in 800 ms fallback. The internal colour-transform fade retains its default. Only the preset's two used custom curves are declared. Noctalia's matched layers still bypass compositor animations, and its own UI animation settings are unchanged. Animation feel needs testing after activation.

| Shortcut | Action |
| --- | --- |
| `Super+H/J/K/L` or arrows | Focus left/down/up/right; left/right traverse grouped windows before leaving the group |
| Add `Shift` | Move the window in that direction |
| `Super+1…9/0` | Select workspace 1…9/10; selecting the current workspace returns to the previous one |
| Add `Shift` | Send the window to that workspace without following it |
| `Super+B` | Select a horizontal split for the next window |
| `Super+E` | Return a group to split tiling; toggling split direction requires `preserve_split = true` |
| `Super+F`, `Super+Shift+F` | Toggle maximized / fullscreen |
| `Super+R` | Resize mode: H/J/K/L or arrows; Escape or Return exits |
| `Super+S/W` | Use a group with stacked/tabbed titles |
| `Super+Shift+Space` | Toggle floating |
| `Super+Alt+Space` | Switch focus between floating and tiled windows |
| `Super+left/right mouse drag` | Move / resize the window |
| `Super+Minus`, `Super+Shift+Minus` | Show the scratchpad / send a window to it |
| `Super+Q/C` | Open Kitty / close the focused window |
| `Super+D` | Noctalia launcher |
| `Super+V` | Clipboard |
| `Super+Shift+S/A/P` | Region / annotated / fullscreen screenshot |
| `Super+Escape` | Lock, including in resize mode |
| `Super+Shift+C` | Reload the configuration |
| `Super+Shift+E` | Confirm logout through a notification, then end the UWSM session |

Volume, microphone mute, media and brightness keys use Noctalia and work while locked and in resize mode. Closing a laptop lid asks Noctalia to lock and suspend. Three-finger horizontal swipes retain Sway's workspace gesture.

Hovering tiled or floating windows sends pointer events, including scrolling, to that window without changing keyboard focus; clicking changes keyboard focus. Floating windows snap to nearby window and monitor edges while dragging. Closing a window returns focus to the most recently used window. Noctalia launches applications as independent systemd user services; its runtime settings can override the declarative base, so keep the corresponding launcher setting enabled in the GUI too.

Firefox picture-in-picture windows float, appear across workspaces, keep their aspect ratio when resized with the mouse, and remember their size for the compositor session. Focused Tencent Meeting windows inhibit idle; fullscreen mpv and gaming windows do so too. These are fallbacks, not meeting-state detection: an unfocused meeting relies on the application's own inhibitor or Noctalia's manual idle inhibitor. Noctalia notification layers and 1Password windows are excluded from screen sharing. XDPH screen sharing is limited to 60 fps, without changing display refresh rates or Noctalia's recording settings.

Hyprland groups approximate Sway's containers: their tab/stack title style applies to all groups, and they do not provide Sway's parent-container focus (`Super+A` is unbound). The special scratchpad workspace shows its floating windows together, whereas Sway cycles individual scratchpad windows. The historical Sway override already replaced `Super+V`'s vertical split with the clipboard. Niri's column, overview, workspace-cycle and wheel bindings are not retained. Hyprland's conflicting defaults yield to the existing keys; pseudotiling is unbound by choice. Hyprland does not provide Niri's automatic touchpad disabling when an external mouse is connected.

Parallax retains DP-1 at 3840×2160@120, scale 1.333333, position 1440×416, with workspace 1 assigned as its default. DP-3 uses 2560×1440@165, scale 1, rotated 270° and positioned at 0×0, with workspace 10 assigned as its default (`Super+0`). This startup default does not rename workspace 2 or move its existing windows.

Asymmetry uses its internal display at 2880×1800@120 and scale 1.666667, giving a 1728×1080 logical desktop. Its `desc:` selector matches the comma-free description from `hyprctl monitors`, rather than the raw EDID manufacturer string; a mismatch falls back to automatic scaling. Hyprland requires whole-pixel logical dimensions, so 1.75 is rounded to 1.8 on this panel.

These settings, animation feel, VRR, suspend, fractional scaling, picture-in-picture and meeting window matching, capture exclusions and the shell's interactions need verification on the actual hosts after activation.
