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
    desktop-apps
    fcitx5
    firefox
    fish
    flatpak
    gdm
    ghostty
    git
    gnome
    herdr
    keyring
    neovim
    netbird-desktop
    obsidian
    omp
    sing-box
    skills
    splayer-next
    starship
    tailscale
    tailscale-desktop
    udiskie
    unix-tools
    vicinae
    xpipe
    zed

    nvirellia
  ];

  flake.modules.nixos.workstation.boot.loader.systemd-boot.configurationLimit = 5;
}
