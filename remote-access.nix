{ config, lib, ... }:

let
  cfg = config.teamRemoteAccess;

  # Same restriction the bootstrap scripts apply: the team key only
  # works for connections that arrive over Tailscale.
  teamKey = ''from="100.64.0.0/10,fd7a:115c:a1e0::/48" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIrh/O8dmsER+IapRrf0jflrWu603Z9Iq/JzMu0VLHi8 colmena-hetzner'';
in
{
  options.teamRemoteAccess.users = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    example = [ "alice" ];
    description = "Existing users that get the team SSH key.";
  };

  config = {
    services.tailscale = {
      enable = true;
    };

    services.openssh = {
      enable = true;

      # Do not open SSH globally.
      openFirewall = false;

      settings = {
        PubkeyAuthentication = true;
        PasswordAuthentication = false;
        KbdInteractiveAuthentication = false;
      };
    };

    users.users = lib.genAttrs cfg.users (_: {
      openssh.authorizedKeys.keys = [ teamKey ];
    });

    networking.firewall = {
      # Helps Tailscale establish direct connections.
      allowedUDPPorts = [
        config.services.tailscale.port
      ];

      # SSH is open only on tailscale0.
      interfaces = {
        "${config.services.tailscale.interfaceName}" = {
          allowedTCPPorts = [ 22 ];
        };
      };
    };
  };
}
