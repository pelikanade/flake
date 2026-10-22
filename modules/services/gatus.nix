_: {
  # Gatus is a single Go binary whose monitors, storage and status page all
  # come from one YAML document, so this feature only binds the web UI to
  # loopback and keeps its SQLite history under the service's StateDirectory.
  # The machine supplies services.gatus.settings.endpoints.
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
