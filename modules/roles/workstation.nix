{ inputs, ... }:
{
  flake.modules.aspects.workstation.imports = with inputs.self.modules.aspects; [
    audio
    bluetooth
    console
    fonts
    networkmanager
    plymouth
    podman
    power
    stylix
    u2f
    zswap

    _1password
    agent-desktops
    delta
    fcitx5
    firefox
    fish
    flatpak
    gdm
    git
    herdr
    keyring
    kitty
    neovim
    netbird-desktop
    hyprland
    noctalia
    obsidian
    omp
    sing-box
    skills
    splayer-next
    starship
    udiskie
    unix-tools
    xpipe
    zed

    nvirellia
  ];

  flake.modules.nixos.workstation =
    { pkgs, ... }:
    {
      boot.kernelPackages = pkgs.linuxPackages_7_2;
      boot.loader.systemd-boot.configurationLimit = 5;
    };
}
