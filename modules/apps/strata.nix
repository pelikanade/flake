_: {
  flake.modules.homeManager.strata =
    { pkgs, ... }:
    {
      # Strata brings its own sandboxed preview stack (see docs/strata.md) and
      # installs the desktop entry and icon, which the session reads from the
      # profile. It claims no defaults: the folder handler, the FileManager1
      # "Open file location" service, and the file chooser portal all stay
      # per-user opt-ins through Settings or `strata --install-*`.
      home.packages = [ pkgs.selfPackages.strata ];
    };
}
