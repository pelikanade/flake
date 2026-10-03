{
  flake.modules.generic.tailnet =
    { config, lib, ... }:
    {
      options.constants.tailnetDnsName = lib.mkOption {
        type = lib.types.str;
        description = ''
          The tailnet's MagicDNS name.

          MagicDNS answers fully qualified names, and the system resolver does not
          expand a bare peer name for them, so consumers address a peer as
          `<peer>.<tailnetDnsName>`.
        '';
      };

      options.constants.getTailnetFqdn = lib.mkOption {
        type = with lib.types; functionTo str;
        readOnly = true;
        description = "Expand a peer's own name into its fully qualified MagicDNS name.";
      };

      config.constants.tailnetDnsName = "leaffish-halfmoon.ts.net";
      config.constants.getTailnetFqdn = name: "${name}.${config.constants.tailnetDnsName}";
    };
}
