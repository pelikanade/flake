{
  flake.diskoConfigurations.ext4-server-bios = {
    disko.devices = {
      disk = {
        main = {
          type = "disk";
          content = {
            type = "gpt";
            partitions = {
              # A BIOS-booted disk keeps GRUB's core image in a partition of its
              # own; disko points `boot.loader.grub.devices` at the disk when
              # this type is present. The machine imports the `bios` aspect,
              # which selects GRUB instead of systemd-boot.
              bios = {
                size = "1M";
                type = "EF02";
              };
              root = {
                end = "-4G";
                content = {
                  type = "filesystem";
                  format = "ext4";
                  mountpoint = "/";
                };
              };
              swap = {
                size = "100%";
                content = {
                  type = "swap";
                };
              };
            };
          };
        };
      };
    };
  };
}
