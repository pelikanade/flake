{
  flake.modules.nixos.substituter-cn = {
    nix.settings.substituters = [
      "https://mirrors.cernet.edu.cn/nix-channels/store"
    ];
  };
}
