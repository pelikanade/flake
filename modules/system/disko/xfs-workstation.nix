{
  flake.diskoConfigurations.xfs-workstation = {
    disko.devices = {
      disk = {
        main = {
          type = "disk";
          content = {
            type = "gpt";
            partitions = {
              ESP = {
                type = "EF00";
                size = "1G";
                content = {
                  type = "filesystem";
                  format = "vfat";
                  mountpoint = "/boot";
                  mountOptions = [ "umask=0077" ];
                };
              };
              root = {
                end = "-32G";
                content = {
                  type = "luks";
                  name = "root";
                  passwordFile = "/run/luks-password";
                  settings.allowDiscards = true;
                  content = {
                    type = "filesystem";
                    format = "xfs";
                    mountpoint = "/";
                    mountOptions = [
                      "defaults"
                      "pquota"
                    ];
                  };
                };
              };
              swap = {
                size = "100%";
                content = {
                  type = "swap";
                  resumeDevice = true;
                };
              };
            };
          };
        };
      };
    };
  };
}
