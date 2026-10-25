_: {
  flake.modules.nixos.gatus = _: {
    services.gatus = {
      enable = true;
      settings = {
        web = {
          address = "127.0.0.1";
          port = 3001;
        };
        storage = {
          type = "sqlite";
          path = "/var/lib/gatus/data.db";
        };
      };
    };
  };
}
