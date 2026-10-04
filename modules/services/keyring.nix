_: {
  # Provides the Secret Service D-Bus API. Zed-based editors (including Delta)
  # store account credentials through it, and login auto-unlock comes from
  # `login`'s `enableGnomeKeyring`, which the GDM module mirrors into its own
  # PAM services.
  flake.modules.nixos.keyring = {
    services.gnome.gnome-keyring.enable = true;
  };
}
