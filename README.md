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
- Test a real SSH login over Tailscale before reporting success (Linux and macOS)
- Print the `~/.ssh/config` entry to use on the computer you connect from

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

- If Homebrew is installed (and writable by your account), the CLI-only
  `tailscaled` is used and registered as a boot daemon with
  `tailscaled install-system-daemon`. This is the best fit for a headless Mac.
- Otherwise (no Homebrew, or Homebrew owned by another account, as on many
  shared Macs) the official Tailscale app is installed. It may ask you to approve
  its network extension in System Settings, so someone needs to be at the machine.
- If Remote Login is limited to **Only these users**, the account is added to
  the `com.apple.access_ssh` group. Without that, macOS rejects the login even
  with a valid key. Active Directory / network accounts are supported. If an
  MDM profile blocks the change, the script stops and says so. On MDM-managed
  Macs (e.g. Jamf), a management policy may reset this group later.
- If Remote Login cannot be turned on automatically (recent macOS requires Full
  Disk Access for this), the script opens **System Settings > General > Sharing**
  and waits up to 5 minutes for you to turn on **Remote Login**.
- Macs managed by nix-darwin are refused. Configure SSH and Tailscale in your
  nix-darwin config instead.

At the end, the script logs in over Tailscale with a throwaway key (restricted
the same way as the team key, and removed afterward). It only prints
**SERVER BOOTSTRAP COMPLETE** if that login worked; otherwise it prints
**NOT READY** with the reason and exits with an error.

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

## Connecting

The computer you connect **from** needs two things:

1. **Tailscale running and signed in to the same tailnet.** The team key is
   only accepted from Tailscale addresses, and SSH traffic only reaches the
   server through Tailscale. If `ssh` just hangs at "Connecting to...", check
   this first: `tailscale ping MACHINE-NAME` must get a `pong`.
2. **The team private key** at `~/.ssh/colmena_hetzner`.

The bootstrap prints the exact `~/.ssh/config` entry for each machine. It
looks like this:

```sshconfig
Host h16003mac
    HostName 100.102.1.90
    User rmccrar6
    IdentityFile ~/.ssh/colmena_hetzner
    IdentitiesOnly yes
```

Then just:

```bash
ssh h16003mac
```

`HostName` is the machine's Tailscale IP, which works whether or not MagicDNS
is on. With MagicDNS enabled you can use `NAME.your-tailnet.ts.net` instead.

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
