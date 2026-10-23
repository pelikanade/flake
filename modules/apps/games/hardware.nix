_: {
  flake.modules.nixos.games-hardware = { pkgs, ... }: {
    services.udev.packages = [ pkgs.game-devices-udev-rules ];
    hardware.uinput.enable = true;
    services.pipewire.wireplumber.extraConfig = {
      "51-dualsense" = {
        "monitor.alsa.rules" = [
          {
            matches = [
              {
                "device.name" = "~alsa_card.usb-Sony_Interactive_Entertainment_DualSense_Wireless_Controller.*";
              }
            ];
            actions."update-props" = {
              "device.description" = "DualSense Wireless Controller";
              "device.nick" = "DualSense";
            };
          }

          {
            matches = [
              {
                "node.name" = "~alsa_output.usb-Sony_Interactive_Entertainment_DualSense_Wireless_Controller.*";
              }
            ];
            actions."update-props" = {
              "node.description" = "Wireless Controller";
              "node.nick" = "Wireless Controller";

              "audio.channels" = 4;
              "audio.position" = [
                "FL"
                "FR"
                "RL"
                "RR"
              ];

              "channelmix.normalize" = false;
              "priority.session" = 2500;
              "priority.driver" = 2500;
              "node.pause-on-idle" = false;
            };
          }
          {
            matches = [
              {
                "node.name" = "~alsa_input.usb-Sony_Interactive_Entertainment_DualSense_Wireless_Controller.*";
              }
            ];
            actions."update-props" = {
              "node.description" = "Wireless Controller Mic";
              "node.nick" = "Wireless Controller Mic";
            };
          }
        ];
      };
    };
  };
}
