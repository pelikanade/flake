# The storage quirk of this phone: its UFS host controller must stay out of
# runtime suspend.
{
  flake.modules.nixos.alioth = _: {
    # The UFS host controller's runtime suspend is the path that took the
    # storage down: with a heavy write burst running, the controller came back
    # from runtime suspend and its vcc rail (PM8150L L17) failed to enable
    # with `-110`, after which it served no IO at all — 99% IO pressure, load
    # 30, and only a power cycle brought it back. Keeping the controller out of
    # runtime suspend stops that path from running; the rails stay powered,
    # which costs nothing on a phone that lives on an adapter.
    services.udev.extraRules = ''
      ACTION=="add", SUBSYSTEM=="platform", DRIVERS=="ufshcd-qcom", ATTR{power/control}="on"
    '';
  };
}
