{
  perSystem =
    { pkgs, ... }:
    {
      # The privileged half of the deploy broker protocol: what
      # `paseo-deploy@.service` runs once per request. `writePython3Bin` writes the
      # interpreter line and lints the source; the unit supplies `nixos-rebuild`
      # and `systemd-run` through its own PATH. See docs/paseo-deploy.md.
      packages.paseo-deploy-broker = pkgs.writers.writePython3Bin "paseo-deploy-broker" { } (
        builtins.readFile ./paseo-deploy-broker.py
      );
    };
}
