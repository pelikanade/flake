{
  flake.modules.nixos.k3s = {
    # k3s's proxy and flannel write their rules into their own tables, and
    # flannel flips that table's FORWARD policy to ACCEPT. This host's firewall
    # is a separate nftables table whose own `forward` policy keeps dropping
    # pod traffic, and whose `input` policy drops the ClusterIP path once k3s
    # has redirected it to a local port — a service VIP then times out from
    # every pod. Admitting the two interfaces pod traffic arrives on is what
    # makes the cluster usable; it says nothing about what reaches the node
    # from anywhere else.
    networking.firewall.trustedInterfaces = [
      "cni0"
      "flannel.1"
    ];

    services.k3s = {
      enable = true;
      role = "server";
    };
  };
}
