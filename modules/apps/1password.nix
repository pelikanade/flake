_: {
  flake.modules.nixos._1password = { config, ... }: {
    programs._1password.enable = true;
    programs._1password-gui = {
      enable = true;
      polkitPolicyOwners = [ config.constants.nvirellia.username ];
    };
  };

  flake.modules.homeManager._1password =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      sshAgentSocket = "${config.home.homeDirectory}/.1password/agent.sock";
    in
    {
      programs.ssh.settings."*".IdentityAgent = sshAgentSocket;

      programs.git.settings = {
        "gpg \"ssh\"".program = lib.getExe' pkgs._1password-gui "op-ssh-sign";
      };
    };
}
