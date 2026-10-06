{
  flake.modules.nixos.nvidia =
    { config, ... }:
    let
      # Linux 7.2 removed strncpy() from the kernel API, and the 595.71.05
      # open modules shipped in nixpkgs 26.05 still call it. Pin the current
      # upstream release until the release branch carries a driver that
      # builds against this kernel.
      nvidiaPackage = config.boot.kernelPackages.nvidiaPackages.mkDriver {
        version = "615.71.09";
        sha256_64bit = "sha256-zc7tIrvrYSSNGm3qvCWWZz46ZQFpjucayNL9wo87cP4=";
        sha256_aarch64 = "sha256-IbekQhE7cFfmnPZaLY9NDYcF7CoNZ+2Qb7sRd4EOgWM=";
        openSha256 = "sha256-3gByMYIwFzRaLdDG+roCEOuKRRJDrljG9AlLnRZTirM=";
        settingsSha256 = "sha256-LK1LU8mDkM/XVRKPBtuOZh9nIP/lGFLAJnmasEX8jhg=";
        persistencedSha256 = "sha256-qPRb+3d88+2RcpUkoBTbjIaImnQ+jX+/6p1vXcJ5geE=";
      };
    in
    {
      hardware = {
        graphics.enable = true;
        nvidia = {
          modesetting.enable = true;
          open = true;
          package = nvidiaPackage;
          # Kernel suspend notifiers let the open modules restore GPU and display
          # state themselves across suspend, instead of the driver refusing the
          # first modeset of a resume and bringing the display back at a low
          # refresh rate (DP-1 has been returning at 3840x2160@29.97). The
          # preservation that comes with them writes every video memory
          # allocation out at suspend, and the open modules back it with tmpfs by
          # default; point it at the root file system so a VRAM-sized image does
          # not have to fit in RAM.
          powerManagement.enable = true;
          moduleParams.nvidia.NVreg_TemporaryFilePath = "/var/tmp";
        };
      };

      boot.initrd.kernelModules = [
        "nvidia"
        "nvidia_modeset"
        "nvidia_drm"
      ];

      services.xserver.videoDrivers = [ "nvidia" ];
    };
}
