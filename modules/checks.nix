{ config, lib, ... }:
let
  configurations = config.flake.nixosConfigurations;
  configurationsWithoutBase = builtins.filter (
    name: !(lib.hasAttrByPath [ "roles" "base" "imported" ] configurations.${name}.options)
  ) (builtins.attrNames configurations);

  linesOf = path: builtins.filter builtins.isString (builtins.split "\n" (builtins.readFile path));

  # The host key of each machine is named by an anchor in `.sops.yaml`, and each
  # encrypted document records the actual keys it was encrypted to in its
  # metadata. Neither requires decryption.
  hostRecipients = builtins.listToAttrs (
    builtins.concatMap (
      line:
      let
        matched = builtins.match " *- &([^ ]+) (age1[0-9a-z]+) *" line;
      in
      lib.optional (matched != null) {
        name = builtins.elemAt matched 0;
        value = builtins.elemAt matched 1;
      }
    ) (linesOf ../.sops.yaml)
  );

  documentRecipients =
    path:
    map builtins.head (
      builtins.filter (matched: matched != null) (
        map (line: builtins.match " *-? *recipient: (age1[0-9a-z]+) *" line) (linesOf path)
      )
    );

  # Activation reads a machine's secret files with its host key, so a document
  # that omits that key fails only when the machine switches. Compare what each
  # configuration reads against the recipients already recorded in the document.
  missingRecipients = lib.concatMap (
    name:
    let
      machine = configurations.${name}.config;
      files = lib.unique (map (secret: secret.sopsFile) (lib.attrValues machine.sops.secrets));
      recipient = hostRecipients.${name} or null;
      notListed = builtins.filter (file: !(builtins.elem recipient (documentRecipients file))) (
        lib.optionals (recipient != null) files
      );
    in
    lib.optionals (recipient == null && files != [ ]) [
      "${name}: .sops.yaml has no `&${name}` age recipient"
    ]
    ++ map (
      file: "${name}: ${builtins.baseNameOf (toString file)} does not list this machine's recipient"
    ) notListed
  ) (builtins.attrNames configurations);
in
{
  perSystem =
    { pkgs, ... }:
    {
      checks = {
        nixos-configurations-import-base =
          assert lib.assertMsg (configurationsWithoutBase == [ ]) ''
            The following NixOS configurations do not import the base role module:
            ${lib.concatStringsSep ", " configurationsWithoutBase}
          '';
          pkgs.runCommand "nixos-configurations-import-base" { } ''
            touch $out
          '';

        sops-recipients =
          assert lib.assertMsg (missingRecipients == [ ]) ''
            These machines read encrypted documents that do not list their host key:
            ${lib.concatStringsSep "\n" missingRecipients}
          '';
          pkgs.runCommand "sops-recipients" { } ''
            touch $out
          '';
      };
    };
}
