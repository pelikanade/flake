{
  flake.modules.nixos.nvidia =
    { config, ... }:
    let
      # Nixpkgs 26.05 still ships 595.71.05. Pin the 615 branch so the
      # suspend path stays on the driver release the workstation kernel is
      # validated against, instead of mixing it with the channel's older
      # modules. 615.71.09 loses the DisplayPort link state across S3 and
      # leaves the resumed output disabled; 615.78.08 carries the fix
      # (open-gpu-kernel-modules#1380).
      nvidiaPackage = config.boot.kernelPackages.nvidiaPackages.mkDriver {
        version = "615.78.08";
        sha256_64bit = "sha256-Pj9t3cLudnoIGFMAr3vjyyhuznZpjS3eNSRZl4LQf/4=";
        sha256_aarch64 = "sha256-UHYBE1AYHoGgMfD9AS/jX+S+N8eCDWUft6qolK9Eejc=";
        openSha256 = "sha256-HBINiOjL0ZJLIAJeNIBYHBnwgUXtNwPPtnFpAI1YwF4=";
        settingsSha256 = "sha256-inDRpG02sdDgHmlqgu/DsgK8OFdOt1fZIYyXdhlGC/c=";
        persistencedSha256 = "sha256-RzeR6Ldct6MUxjnXRyThdh5Y3jjMehTVg85MtwuWNX4=";
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
