{ inputs, ... }:
{
  machines.installer = {
    system = "x86_64-linux";
    tags = [ "installer" ];
    imports = with inputs.self.modules.aspects; [
      base
      installer
      i18n
      substituter-cn
    ];
    hardware = {
      networking.hostName = "installer";
    };
  };
}
