# Server Bootstrap

Quickly turn a Windows, Linux, macOS, or NixOS machine into an SSH-accessible server over Tailscale.

The bootstrap scripts:

- Install and enable OpenSSH
- Install and start Tailscale
- Add the team SSH public key
- Disable SSH password authentication
- Restrict the team SSH key to Tailscale connections
- Enable services at startup
- Run Tailscale login if the machine is not already authenticated
- Print the Tailscale IP and SSH command when finished

> **Heads up:** password and keyboard-interactive SSH logins are turned off for
> **every** account on the machine, not just the team key. Anyone who currently
> logs in over SSH with a password will need a key first. Other existing keys in
> `authorized_keys` are left alone.

## Windows

Open **PowerShell as Administrator** and run:

```powershell
irm https://raw.githubusercontent.com/RobertLMcCrary/MachineScripts/main/bootstrap.ps1 | iex
```

Complete the Tailscale login if prompted.

On Windows, the default all-interface SSH firewall rule is disabled and replaced
with one that only accepts connections from Tailscale addresses.

After setup:

```powershell
tailscale status
tailscale ip -4
```

Then SSH into the machine from another device on the tailnet:

```bash
ssh USERNAME@100.x.x.x
```

## Linux and macOS

Run this from bash, zsh, or any POSIX shell:

```bash
curl -fsSL https://raw.githubusercontent.com/RobertLMcCrary/MachineScripts/main/bootstrap.sh | bash
```

You may be prompted for your `sudo`/administrator password and Tailscale login.

On Linux, port 22 stays reachable on every interface (the firewall is not
changed), but only key logins work and the team key is only accepted from
Tailscale addresses.

On macOS:

- If Homebrew is installed, the CLI-only `tailscaled` is used. This is the best
  fit for a headless Mac.
- Otherwise the official Tailscale app is installed. It may ask you to approve
  its network extension in System Settings, so someone needs to be at the machine.
- If Remote Login cannot be turned on automatically (recent macOS requires Full
  Disk Access for this), the script tells you to enable it under
  **System Settings > General > Sharing > Remote Login**.
- Macs managed by nix-darwin are refused. Configure SSH and Tailscale in your
  nix-darwin config instead.

Check the machine afterward:

```bash
tailscale status
tailscale ip -4
```

Connect with:

```bash
ssh USERNAME@100.x.x.x
```

### Unattended Tailscale login

Both scripts accept a Tailscale auth key from the environment instead of the
interactive login:

```bash
curl -fsSL https://raw.githubusercontent.com/RobertLMcCrary/MachineScripts/main/bootstrap.sh | TS_AUTH_KEY=tskey-... bash
```

```powershell
$env:TS_AUTH_KEY = 'tskey-...'
irm https://raw.githubusercontent.com/RobertLMcCrary/MachineScripts/main/bootstrap.ps1 | iex
```

Never commit an auth key to this repository.

## NixOS

The shell script refuses to run on NixOS. Import `remote-access.nix` into your
configuration and list the users that should get the team key:

```nix
{
  imports = [ ./remote-access.nix ];

  teamRemoteAccess.users = [ "your-user" ];
}
```

Then rebuild and log in to Tailscale once:

```bash
sudo nixos-rebuild switch
sudo tailscale up
```

SSH is only opened in the firewall on the Tailscale interface. If you deploy to
the machine over its public IP (e.g. with Colmena), switch the deployment target
to its Tailscale address first, or you will lock yourself out.
