{
  flake.modules.generic.tailnet =
    { config, lib, ... }:
    {
      options.constants.tailnetDnsName = lib.mkOption {
        type = lib.types.str;
        description = ''
          The tailnet's MagicDNS name.

          MagicDNS answers fully qualified names, so a consumer addresses a peer
          as `<peer>.<tailnetDnsName>`: that name resolves through the tailnet's
          routing domain, which the node publishes to the system resolver,
          without depending on any search list.
        '';
      };

      options.constants.getTailnetFqdn = lib.mkOption {
        type = with lib.types; functionTo str;
        readOnly = true;
        description = "Expand a peer's own name into its fully qualified MagicDNS name.";
      };

      config.constants.tailnetDnsName = "dwelf-hoki.ts.net";
      config.constants.getTailnetFqdn = name: "${name}.${config.constants.tailnetDnsName}";
    };
}
