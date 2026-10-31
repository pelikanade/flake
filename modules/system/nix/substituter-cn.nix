{
  flake.modules.nixos.substituter-cn = {
    # NixOS appends cache.nixos.org to whatever is listed here, which is what
    # covers the fresh paths a mirror's dynamic cache has not picked up yet.
    nix.settings.substituters = [
      "https://mirrors.tuna.tsinghua.edu.cn/nix-channels/store"
      "https://mirror.sjtu.edu.cn/nix-channels/store"
    ];
  };
}
