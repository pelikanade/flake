{ inputs, ... }:
{
  machines.stylix-test = {
    system = "x86_64-linux";
    imports = with inputs.self.modules.aspects; [
      base
      i18n
      fonts
      stylix

      firefox
      fish
      kitty
      ly
      neovim
      hyprland
      noctalia

      nvirellia
    ];
    hardware =
      {
        modulesPath,
        ...
      }:
      {
        imports = [ (modulesPath + "/virtualisation/qemu-vm.nix") ];

        environment.sessionVariables.LIBGL_ALWAYS_SOFTWARE = "1";

        networking.hostName = "stylix-test";

        services.displayManager.autoLogin = {
          enable = true;
          user = "nvirellia";
        };

        virtualisation = {
          cores = 4;
          diskSize = 16 * 1024;
          graphics = true;
          memorySize = 4 * 1024;
        };
      };
    homeModule = { lib, ... }: {
      wayland.windowManager.hyprland.settings.on._args = lib.mkForce [
        "hyprland.start"
        (lib.generators.mkLuaInline ''
          function()
            hl.exec_cmd("uwsm app -- kitty --title 'Stylix · Neovim' nvim")
            hl.exec_cmd("uwsm app -- firefox")
          end
        '')
      ];
    };
  };
}
