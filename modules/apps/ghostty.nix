_: {
  flake.modules.homeManager.ghostty =
    {
      lib,
      pkgs,
      ...
    }:
    {
      programs.ghostty = {
        enable = true;
        settings = {
          mouse-hide-while-typing = false;
          cursor-style = "bar";
          cursor-style-blink = false;
          command = lib.getExe pkgs.fish;
          window-decoration = false;
          background-blur = true;
          # Stylix's Ghostty target defaults to its generated theme; use the
          # built-in Nord theme instead.
          theme = lib.mkForce "Nord";
          /*
            Stylix's Ghostty target supplies FiraCode Nerd Font followed by the
            emoji font. Append a Chinese fallback after them.

            Ghostty only applies ideograph-width size adjustment to fallback
            faces it discovers through Fontconfig; families named here keep
            their natural metrics, so the named font must fit the two-cell slot
            itself. Maple Mono NF CN advances ideographs by 1.2em against
            FiraCode's two cells of 2 x 0.615em, which fills the slot and keeps
            wide glyphs centred. Noto Sans Mono CJK SC advances them by 1.0em,
            leaving a fifth of the slot empty and shifting wide glyphs left.

            Blocks Maple lacks, such as CJK Ext-A and compatibility ideographs,
            still come from discovery.
          */
          font-family = lib.mkAfter [ "Maple Mono NF CN" ];
        };
      };
    };
}
