_: {
  # KIO, not GVfs: Dolphin's wrapper already puts `kio-extras` -- the `smb`,
  # `sftp`, `nfs`, `mtp`, and `afc` workers that browse network shares and phone
  # storage -- on its own `QT_PLUGIN_PATH` and `XDG_DATA_DIRS`, so the aspect
  # claims nothing on the NixOS side.
  flake.modules.homeManager.dolphin =
    { pkgs, ... }:
    {
      home.packages = [ pkgs.kdePackages.dolphin ];

      # Dolphin ships this service file for `org.freedesktop.FileManager1`, the
      # name other applications use for "Reveal in file manager" and "Open
      # containing folder", but its `SystemdService=plasma-dolphin.service`
      # cannot resolve here: dbus-broker activates through systemd and reports
      # `activation request failed: unknown unit` instead of falling back to
      # `Exec`, so the name would never be owned. This copy under
      # `$XDG_DATA_HOME/dbus-1/services`, which the session bus searches before
      # the profile's service directories, drops that key and names the wrapper,
      # so a D-Bus-activated instance gets the same KIO and GStreamer
      # environment as a launched one.
      #
      # The folder handler is deliberately not claimed: `xdg.mimeApps` writes
      # ~/.config/mimeapps.list as a store symlink, so the desktop's own
      # default-application panel could never rewrite it. The package's desktop
      # entry claims `inode/directory` on its own, and no other file manager is
      # installed to compete with it.
      xdg.dataFile."dbus-1/services/org.kde.dolphin.FileManager1.service".text = ''
        [D-BUS Service]
        Name=org.freedesktop.FileManager1
        Exec=${pkgs.kdePackages.dolphin}/bin/dolphin --daemon
      '';
    };
}
