# The Xiaomi POCO F3 / Redmi K40 / Mi 11X that runs NixOS from its boot and
# userdata partitions. The device support, including the kernel and the two
# images the phone boots from, is in modules/devices/alioth.
{
  inputs,
  ...
}:
{
  machines.alioth = {
    system = "aarch64-linux";
    imports = with inputs.self.modules.aspects; [
      base
      server
      tailscale
      alioth
    ];
    hardware = {
      networking.hostName = "alioth";
    };
  };
}
