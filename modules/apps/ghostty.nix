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
          # Kitty's mouse_hide_wait = -1 never hides the pointer.
          mouse-hide-while-typing = false;
          cursor-style = "bar";
          cursor-style-blink = false;
          command = lib.getExe pkgs.fish;
          window-decoration = false;
          background-blur = true;
          # Stylix's Ghostty target defaults to its generated theme; use the
          # built-in Nord theme instead.
          theme = lib.mkForce "Nord";
        };
      };
    };
}
