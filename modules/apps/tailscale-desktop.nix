{
  flake.modules.nixos.tailscale-desktop =
    { config, ... }:
    {
      # tailscaled's LocalAPI socket belongs to root, and its operator setting
      # hands it to one account. The CLI, Trayscale and anything else that reads or
      # writes the node's state run as that account instead of through sudo, which
      # is also what makes `tailscale serve` and `tailscale status` usable from an
      # ordinary shell.
      services.tailscale.extraSetFlags = [ "--operator=${config.constants.nvirellia.username}" ];

      # The node's TLS certificates come from the tailnet, and `tailscale cert`
      # refuses an unprivileged caller unless that caller is named here. Serve's own
      # TLS termination does not need it; a human issuing a certificate by hand does.
      services.tailscale.permitCertUid = config.constants.nvirellia.username;
    };

  flake.modules.homeManager.tailscale-desktop =
    { pkgs, ... }:
    {
      home.packages = [ pkgs.trayscale ];
    };
}
