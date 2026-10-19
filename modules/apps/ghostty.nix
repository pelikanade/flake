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
        };
      };
    };
}
