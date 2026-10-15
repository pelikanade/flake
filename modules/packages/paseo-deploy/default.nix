{
  perSystem =
    { pkgs, ... }:
    {
      # The client half of the deploy broker protocol: what the Paseo account runs
      # to ask this host for a deployment. `writePython3Bin` writes the interpreter
      # line and lints the source, so the file itself carries neither a shebang nor
      # a runtime dependency of its own. See docs/paseo-deploy.md.
      packages.paseo-deploy = pkgs.writers.writePython3Bin "paseo-deploy" { } (
        builtins.readFile ./paseo-deploy.py
      );
    };
}
