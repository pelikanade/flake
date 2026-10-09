{
  perSystem =
    { pkgs, ... }:
    {
      packages.omp-magpie = pkgs.runCommand "omp-magpie-1.0.0" { } ''
        mkdir -p $out/share/omp/extensions/magpie
        cp ${./index.ts} $out/share/omp/extensions/magpie/index.ts
        cp ${./package.json} $out/share/omp/extensions/magpie/package.json
      '';
    };
}
