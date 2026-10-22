{
  flake.modules.nixos.nvidia =
    { config, ... }:
    let
      # Nixpkgs 26.05 still ships 595.71.05. The 615 branch never wakes a
      # DisplayPort monitor that entered DPMS sleep, and loses the link on S3
      # resume; neither 615.71.09 nor 615.78.08 is usable. NVIDIA fixed it in
      # the Windows 617.14 driver, which has no Linux release yet, so stay on
      # the last known-good 610 branch. Linux 7.2 needed 615 to build, but the
      # workstation is back on 6.18 LTS (open-gpu-kernel-modules#1380).
      nvidiaPackage = config.boot.kernelPackages.nvidiaPackages.mkDriver {
        version = "610.57.04";
        sha256_64bit = "sha256-suk1xmuDuwDAyFe8jg7g/VLekoa0DJzB7sKafOfrEW0=";
        openSha256 = "sha256-rQHOOOY4KL92Ww3KDwh+j4eGU7oNAH8LutZC5wmFnPo=";
        settingsSha256 = "sha256-ZEMo8I8Zc2Tq6RVDNYpAH+f094dUaZiBqO+5f6lIjRI=";
        persistencedSha256 = "sha256-aXmD2VY1RLlgAnlHhOUMWzvMyhI6JTClcFLm4imF/mA=";
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
