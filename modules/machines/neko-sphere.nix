{ inputs, ... }: {
  machines.neko-sphere = {
    system = "x86_64-linux";
    imports = with inputs.self.modules.aspects; [
      base
      server
      efi
      i18n
      substituter-cn
      sing-box
      magpie
      netbird-userspace
      obsidian-headless
      podman
      portainer
      paseo-daemon
      gh
      ingress
    ];
    diskoConfig = inputs.self.diskoConfigurations.workstation-legacy;
    hardware =
      {
        config,
        lib,
        modulesPath,
        ...
      }:
      {
        imports = [
          (modulesPath + "/installer/scan/not-detected.nix")
        ];

        # Every service this host runs is published here, under the zone whose
        # records point at this host; the ingress module knows about TLS and
        # reachability, not about which services exist. One interface carries both
        # the LAN and the machine's public addresses, so the LAN is admitted as a
        # source rather than an interface.
        services.ingress = {
          domain = "neko-sphere.nvirellia.im";
          lanSources = [ "10.0.0.0/24" ];

          proxies = {
            # Magpie's browser page and its gateway API are one process on two
            # ports; the API takes its own name so every route upstream serves
            # stays reachable without guessing path prefixes.
            magpie = {
              upstream = "127.0.0.1:3430";
            };
            magpie-api = {
              upstream = "127.0.0.1:3425";
            };

            # Portainer serves its own listener with the self-signed certificate
            # it generates into /data.
            portainer = {
              upstream = "https://127.0.0.1:9443";
              upstreamInsecureTls = true;
            };

            # The Paseo daemon serves HTTP and WebSocket on one port.
            paseo = {
              upstream = "127.0.0.1:6767";
            };
          };
        };

        networking = {
          hostName = "neko-sphere";
          domain = "lotus.local";
        };
        boot.initrd.availableKernelModules = [ "nvme" ];
        boot.initrd.kernelModules = [ "dm-snapshot" ];
        boot.kernelModules = [ "kvm-amd" ];
        boot.extraModulePackages = [ ];
        disko.devices.disk.main.device = "/dev/nvme0n1";

        hardware.cpu.amd.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;
      };
    # Agents hosted here commit as the paseo service account and as root, and
    # neither runs Home Manager, so this machine's author identity belongs in the
    # system-wide gitconfig that both read.
    nixosModule = {
      programs.git.config.user = {
        name = "Felis catus 'Clonazepam' Suzume";
        email = "suzume@neko-sphere.lotus.local";
      };

      # Another network's HTTP endpoint, served here on loopback. Neither the
      # endpoint's address nor the network it belongs to is public: the client's
      # management URL and setup key come from its own encrypted document.
      services.netbird-userspace.tunnels.techinteaching = {
        localPort = 18083;
        address = "172.0.161.24";
        port = 8083;
      };
    };
  };
}
