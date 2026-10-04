{
  flake.modules.nixos.u2f = {
    security.pam.u2f = {
      control = "sufficient";
      settings = {
        authfile = "/etc/u2f-mappings";
        origin = "pam://nvirellia";
        cue = true;
        userpresence = 0;
      };
    };

    security.pam.services = {
      login.u2f.enable = true;
      sudo.u2f.enable = true;
    };

    environment.etc."u2f-mappings".text =
      "nvirellia:YrvbuSziBDgXkUw4+uonGHaC0lhdAXKNJRkiwfgx7P/GXQrF4pexZ6V4RtiD2o5Sqei0E1MPB09a45XFvg3NNBHhCoG2/ybU+Y6Ax6BQ7nb28yvrjeXyhtuTX+eETe58,luPqci9Gcyfo1cJgA1TPzjK37t+8m8UzBQSwC/M0sBsbTrynuKPFVyOy4B+D49IfwhzIfKDiuO40L5aOD+fIXQ==,es256,\n";
  };
}
