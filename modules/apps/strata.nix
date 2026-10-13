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

      # This is the workstation's file manager: it owns folder handling, and the
      # D-Bus FileManager1 name that other applications use for "Reveal in file
      # manager" and "Open containing folder". The Exec path is the wrapper, so
      # the D-Bus-activated instance gets the same GIO and GStreamer environment
      # as a launched one. The file chooser portal stays a separate opt-in.
      xdg.mimeApps = {
        enable = true;
        defaultApplications."inode/directory" = "io.github.lgse.Strata.desktop";
      };
      xdg.dataFile."dbus-1/services/io.github.lgse.Strata.FileManager1.service".text = ''
        [D-BUS Service]
        Name=org.freedesktop.FileManager1
        Exec=${pkgs.selfPackages.strata}/bin/strata --gapplication-service
      '';
    };
}
