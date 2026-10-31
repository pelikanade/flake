# Font rendering

The desktop draws text with FreeType's stem darkening, which is what keeps
medium and small text legible on these panels, and with two Fontconfig rules that
work around what darkening does badly. Everything is declared in
`modules/services/fonts.nix` — no package is built and no input is pinned for it.

| Setting | Where it lives | What it does |
| --- | --- | --- |
| `FREETYPE_PROPERTIES` | `environment.sessionVariables` (NixOS), and the Flatpak sandbox's own environment | Turns stem darkening on for the autofitter, CFF, Type 1 and CID drivers, and sets its amounts (`500,400,1000,400,2500,400,4000,0` — size/amount pairs) |
| `QT_NO_SYNTHESIZED_BOLD` | same | Stops Qt from synthesizing bold on top of a variable font's own weight |
| `20-stem-darkening-embolden.conf` | the user's `conf.d`, and the sandbox's generated `FONTCONFIG_FILE` | Emboldens text below 14 px, where darkening has little to work with |
| `70-icon-fonts-no-embolden.conf` | same | Keeps the icon fonts this desktop installs — Symbols Nerd Font and Symbols Nerd Font Mono — out of both the emboldening and hinting, which otherwise inflate a font that draws single symbols |
| `fonts.fontconfig.hinting = "slight"`, `subpixelRendering = "none"` | Home Manager, `modules/services/fonts.nix` | The hinting style and antialiasing the rules above are calibrated for, pinned so a change in either default cannot silently alter the rendering |
| `org.gnome.desktop.interface font-antialiasing` | the `gnome` aspect | The same antialiasing where GNOME resolves fonts itself, which is the path GTK applications take |

The two variables are session variables rather than shell ones because
libfreetype and Qt read them when they initialise: a shell profile would leave
every application the session starts without them. `environment.sessionVariables`
is what PAM hands the session, and it reaches both the GNOME session GDM starts
and the systemd user units (Ghostty's). A Flatpak sandbox inherits
neither, which is why the flatpak aspect names the variables, the rules and the
directory holding them.

## What is deliberately not here

Grayscale antialiasing and the light hinting style are already the machine's
state: NixOS' `fontconfig` package installs `10-sub-pixel-none.conf` and
`10-hinting-slight.conf` into `/etc/fonts/conf.d`, and the freedesktop runtime
Flatpak applications run against installs the same two files into its own
`conf.d`. Only the two rules above therefore add anything, and only they are
carried into the sandbox.

The rules themselves come from lucidglyph v0.16.0 (GPL-3.0-or-later), inlined
here rather than depended on. Parts of that project this desktop has no use for
are left out: rejecting Droid Sans (no Droid font is installed here — `fc-list`
finds none, and the freedesktop runtime's font set does not carry one either) and
the charset heuristic that guesses at icon fonts (experimental, while this
repository knows which icon fonts it installs).

## Where it cannot apply

Chromium's font stack no longer goes through FreeType (Fontations and Skrifa,
since Chromium 133), so the Electron applications here — Obsidian, Slack, Zed,
XPipe, Clawd — do not get stem darkening, and neither do the Flatpak
applications that ship their own Chromium. Firefox does.

## Checking it

```sh
# the rule files the session loads, and the ones the sandbox does
fc-conflist | grep -E 'hm-(stem-darkening|icon-fonts)'

# the rules themselves: text below 14 px is emboldened, an icon font is not
fc-match -v 'Noto Sans:pixelsize=12' | grep embolden
fc-match -v 'Symbols Nerd Font:pixelsize=12' | grep -E 'embolden|hinting'

# the environment the session was started with
systemctl --user show-environment | grep -E 'FREETYPE_PROPERTIES|QT_NO_SYNTHESIZED_BOLD'

flatpak run --command=sh com.jetbrains.DataGrip -c \
  'echo "$FREETYPE_PROPERTIES"; fc-match -v "Noto Sans:pixelsize=12" | grep embolden'
```

What no command settles is how the result looks, since both rules are judgement
calls about glyph weight at small sizes. If text below 14 px reads too heavy,
drop the `stem-darkening-embolden` entry from `fonts.fontconfig.configFile`; if
another icon font renders too heavy, name its family in the `iconFonts` rule of
`modules/services/fonts.nix`, which is the one place both the session and the
sandbox read from.
