{
  flake.modules.nixos.substituter-cn = {
    # Measured from parallax on 2026-10-31 over `vicinae-0.23.2` (12.7 MB of
    # nar.xz): TUNA held 30.1 and 30.9 MB/s across runs, SJTU 32.0 and 43.8 MB/s
    # but 4.3 MB/s in an earlier run, SUSTech 17-20 MB/s, BFSU 12-14 MB/s and
    # cache.nixos.org 7.2 MB/s. CERNET and USTC answered no narinfo for that path
    # at all, so they are not named here; TUNA leads because it is the fastest of
    # the two that did, and the one whose rate did not vary.
    #
    # NixOS appends cache.nixos.org to whatever is listed here, which is what
    # covers the fresh paths a mirror's dynamic cache has not picked up yet.
    nix.settings.substituters = [
      "https://mirrors.tuna.tsinghua.edu.cn/nix-channels/store"
      "https://mirror.sjtu.edu.cn/nix-channels/store"
    ];
  };
}
