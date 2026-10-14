_: {
  flake.modules.nixos.strata = {
    # Remote locations -- SMB shares, SFTP servers, phone storage -- are GIO
    # mounts backed by GVfs, which Strata browses like any other location.
    services.gvfs.enable = true;
  };

  flake.modules.homeManager.strata =
    { pkgs, ... }:
    {
      home.packages = [ pkgs.selfPackages.strata ];

      # The folder handler is deliberately not claimed: `xdg.mimeApps` writes
      # ~/.config/mimeapps.list as a store symlink, so the desktop's own
      # default-application panel could never rewrite it. Folder handling and the
      # file chooser portal stay the user's choice.
      #
      # The D-Bus FileManager1 name that other applications use for "Reveal in
      # file manager" and "Open containing folder" is a per-user service instead,
      # because upstream installs it under $XDG_DATA_HOME. The Exec path is the
      # wrapper, so the D-Bus-activated instance gets the same GIO and GStreamer
      # environment as a launched one.
      xdg.dataFile."dbus-1/services/io.github.lgse.Strata.FileManager1.service".text = ''
        [D-BUS Service]
        Name=org.freedesktop.FileManager1
        Exec=${pkgs.selfPackages.strata}/bin/strata --gapplication-service
      '';
    };
}
