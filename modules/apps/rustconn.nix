{ inputs, ... }:
{
  flake-file.inputs.rustconn = {
    url = "github:totoshko88/RustConn";

    # The flake builds RustConn from source against its own nixpkgs. GTK4,
    # WebKitGTK and the embedded clients link against the host's graphics and
    # display stack, so follow this system's nixpkgs as the delta input does.
    inputs.nixpkgs.follows = "nixpkgs";
  };

  flake.modules.homeManager.rustconn =
    { pkgs, ... }:
    {
      home.packages = [ inputs.rustconn.packages.${pkgs.stdenv.hostPlatform.system}.default ];
    };
}
