#!/usr/bin/env bash
set -eu

PUBLIC_KEY='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIrh/O8dmsER+IapRrf0jflrWu603Z9Iq/JzMu0VLHi8 colmena-hetzner'

TAILSCALE_V4='100.64.0.0/10'
TAILSCALE_V6='fd7a:115c:a1e0::/48'

KEY_BLOB="$(printf '%s\n' "$PUBLIC_KEY" | awk '{print $2}')"

# Restrict THIS key so it only works over a Tailscale connection.
AUTHORIZED_KEY="from=\"${TAILSCALE_V4},${TAILSCALE_V6}\" ${PUBLIC_KEY}"

log() {
    printf '\n==> %s\n' "$*"
}

warn() {
    printf '\nWARNING: %s\n' "$*" >&2
}

die() {
    printf '\nERROR: %s\n' "$*" >&2
    exit 1
}

have() {
    command -v "$1" >/dev/null 2>&1
}

as_root() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    else
        sudo "$@"
    fi
}

# ------------------------------------------------------------
# Detect OS
# ------------------------------------------------------------

OS="$(uname -s)"

case "$OS" in
    Darwin)
        PLATFORM='macos'
        ;;
    Linux)
        PLATFORM='linux'
        ;;
    *)
        die "Use bootstrap.ps1 on Windows."
        ;;
esac

# NixOS should be configured declaratively.
if [ "$PLATFORM" = 'linux' ] && [ -e /etc/NIXOS ]; then
    die "NixOS detected. Use the NixOS module provided with this bootstrap."
fi

# nix-darwin manages /etc/ssh too; edits here would be overwritten or fail.
if [ "$PLATFORM" = 'macos' ] && [ -e /run/current-system/darwin-version ]; then
    die "nix-darwin detected. Configure SSH and Tailscale in your nix-darwin config instead."
fi

TARGET_USER="${BOOTSTRAP_USER:-${SUDO_USER:-${USER:-$(id -un)}}}"
# Numeric gid: directory-service group names like "WIN\Domain Users"
# contain spaces and backslashes.
TARGET_GROUP="$(id -g "$TARGET_USER")" ||
    die "Unknown user: $TARGET_USER"

if [ "$PLATFORM" = 'macos' ]; then
    # dscacheutil searches every directory node, so this also works for
    # Active Directory / network accounts that have no local record.
    TARGET_HOME="$(
        dscacheutil -q user -a name "$TARGET_USER" 2>/dev/null |
        sed -n 's/^dir: //p' |
        head -n 1
    )"

    if [ -z "$TARGET_HOME" ]; then
        TARGET_HOME="$(
            dscl /Search -read "/Users/$TARGET_USER" NFSHomeDirectory 2>/dev/null |
            sed -n 's/^NFSHomeDirectory: //p' |
            head -n 1
        )"
    fi
else
    TARGET_HOME="$(
        getent passwd "$TARGET_USER" 2>/dev/null |
        cut -d: -f6
    )"
fi

[ -n "$TARGET_HOME" ] ||
    die "Could not determine home directory for $TARGET_USER"

log "Target account: $TARGET_USER"
log "Target home: $TARGET_HOME"

# Ask for the sudo password once, up front. With `curl | bash` stdin is the
# pipe, so sudo needs a real terminal (it reads from /dev/tty).
if [ "$(id -u)" -ne 0 ] && ! sudo -n true 2>/dev/null; then
    if ! (: </dev/tty) 2>/dev/null; then
        die "sudo needs a password but there is no terminal to ask in. Run this from a Terminal window (or as root)."
    fi

    log "Administrator access is required"

    sudo -v </dev/tty ||
        die "Could not get administrator access."
fi

# ------------------------------------------------------------
# authorized_keys
# ------------------------------------------------------------

AUTH_FILE="$TARGET_HOME/.ssh/authorized_keys"

# Drop every line containing key blob $1, then append line $2 if given.
rewrite_authorized_keys() {
    local drop_blob="$1"
    local add_line="${2:-}"
    local tmp

    # An empty pattern could match every line and wipe the file.
    [ -n "$drop_blob" ] ||
        die "Refusing to rewrite $AUTH_FILE without a key to match."

    tmp="$(mktemp)"

    as_root awk \
        -v blob="$drop_blob" \
        'index($0, blob) == 0 { print }' \
        "$AUTH_FILE" > "$tmp"

    if [ -n "$add_line" ]; then
        printf '%s\n' "$add_line" >> "$tmp"
    fi

    as_root cp "$tmp" "$AUTH_FILE"

    rm -f "$tmp"

    as_root chown \
        "$TARGET_USER:$TARGET_GROUP" \
        "$AUTH_FILE"

    as_root chmod 600 "$AUTH_FILE"
}

install_authorized_key() {
    log "Installing team SSH public key"

    as_root install \
        -d \
        -m 700 \
        -o "$TARGET_USER" \
        -g "$TARGET_GROUP" \
        "$TARGET_HOME/.ssh"

    as_root touch "$AUTH_FILE"

    # Replaces an older copy of this exact key, if present.
    rewrite_authorized_keys "$KEY_BLOB" "$AUTHORIZED_KEY"
}

# ------------------------------------------------------------
# Linux OpenSSH
# ------------------------------------------------------------

install_openssh_linux() {
    if have sshd || [ -x /usr/sbin/sshd ]; then
        return
    fi

    log "Installing OpenSSH server"

    if have apt-get; then

        as_root apt-get update
        as_root apt-get install -y openssh-server

    elif have dnf; then

        as_root dnf install -y openssh-server

    elif have yum; then

        as_root yum install -y openssh-server

    elif have pacman; then

        as_root pacman -S --needed --noconfirm openssh

    elif have zypper; then

        as_root zypper --non-interactive install openssh-server

    elif have apk; then

        as_root apk add openssh

    else

        die "Unsupported Linux package manager for OpenSSH."

    fi
}

# ------------------------------------------------------------
# sshd_config editing
# ------------------------------------------------------------

set_sshd_directive() {
    local file="$1"
    local key="$2"
    local value="$3"
    local tmp

    tmp="$(mktemp)"

    as_root awk \
        -v wanted="$key" \
        -v value="$value" '
        BEGIN {
            done = 0
            wanted_l = tolower(wanted)
        }

        {
            probe = $0

            sub(/^[[:space:]]+/, "", probe)

            split(probe, fields, /[[:space:]]+/)

            first = tolower(fields[1])

            if (!done && first == wanted_l) {
                print wanted " " value
                done = 1
                next
            }

            # Global sshd options must occur before Match blocks.
            if (!done && first == "match") {
                print wanted " " value
                done = 1
            }

            print $0
        }

        END {
            if (!done) {
                print wanted " " value
            }
        }
    ' "$file" > "$tmp"

    as_root cp "$tmp" "$file"

    rm -f "$tmp"
}

configure_sshd_key_only() {
    local config='/etc/ssh/sshd_config'
    local backup="${config}.team-bootstrap.bak"
    local sshd_bin

    [ -f "$config" ] ||
        die "$config does not exist"

    sshd_bin="$(command -v sshd 2>/dev/null || true)"

    if [ -z "$sshd_bin" ]; then
        sshd_bin='/usr/sbin/sshd'
    fi

    [ -x "$sshd_bin" ] ||
        die "Could not find sshd"

    log "Configuring SSH for public-key-only authentication"

    # Ubuntu's socket-activated sshd may not have created this yet,
    # and sshd -t fails without it.
    if [ "$PLATFORM" = 'linux' ]; then
        as_root mkdir -p /run/sshd
    fi

    # sshd -t and -T exit with "no hostkeys available" until host keys
    # exist. A fresh Mac only creates them on the first incoming SSH
    # connection (and Arch on first sshd start), which is after this check.
    # -A only generates the key types that are missing.
    as_root ssh-keygen -A >/dev/null

    if as_root grep -Eiq \
        '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/' \
        "$config"
    then

        # sshd keeps the first value it sees, and the Include sits at the
        # top of sshd_config, so drop-ins (e.g. Ubuntu's 50-cloud-init.conf)
        # beat anything we write to the main file. Sort first instead.
        local dropin='/etc/ssh/sshd_config.d/00-team-bootstrap.conf'

        as_root mkdir -p /etc/ssh/sshd_config.d

        printf '%s\n' \
            '# Managed by the team server bootstrap.' \
            'PubkeyAuthentication yes' \
            'PasswordAuthentication no' \
            'KbdInteractiveAuthentication no' |
            as_root tee "$dropin" >/dev/null

        as_root chmod 644 "$dropin"

        if ! as_root "$sshd_bin" -t -f "$config"; then

            as_root rm -f "$dropin"

            die "Invalid sshd configuration. Removed $dropin."

        fi

    else

        if [ ! -f "$backup" ]; then
            as_root cp "$config" "$backup"
        fi

        set_sshd_directive \
            "$config" \
            'PubkeyAuthentication' \
            'yes'

        set_sshd_directive \
            "$config" \
            'PasswordAuthentication' \
            'no'

        set_sshd_directive \
            "$config" \
            'KbdInteractiveAuthentication' \
            'no'

        # Validate before restarting sshd.
        if ! as_root "$sshd_bin" -t -f "$config"; then

            warn "Invalid sshd configuration."

            as_root cp \
                "$backup" \
                "$config"

            die "Restored original sshd_config."

        fi

    fi

    verify_sshd_key_only "$sshd_bin" "$config"
}

# Ask sshd what it will actually use, so we never report
# "password authentication is disabled" when it is not.
verify_sshd_key_only() {
    local sshd_bin="$1"
    local config="$2"
    local effective

    effective="$(as_root "$sshd_bin" -T -f "$config" 2>/dev/null || true)"

    if [ -z "$effective" ]; then
        warn "Could not read the effective sshd config."
        warn "Check it manually with: sudo $sshd_bin -T | grep -i authentication"
        return
    fi

    if ! printf '%s\n' "$effective" |
        grep -qix 'passwordauthentication no'
    then
        die "sshd still allows password authentication. Look for an override with: grep -ri passwordauthentication /etc/ssh"
    fi

    if printf '%s\n' "$effective" |
        grep -qix 'kbdinteractiveauthentication yes'
    then
        die "sshd still allows keyboard-interactive authentication. Look for an override with: grep -ri kbdinteractive /etc/ssh"
    fi
}

# ------------------------------------------------------------
# Linux sshd service
# ------------------------------------------------------------

start_sshd_linux() {
    log "Enabling SSH at boot"

    if have systemctl; then

        local service_name='sshd'

        if systemctl cat ssh.service >/dev/null 2>&1; then
            service_name='ssh'
        fi

        as_root systemctl enable "$service_name"
        as_root systemctl restart "$service_name"

    elif have rc-update && have rc-service; then

        as_root rc-update add sshd default || true

        as_root rc-service sshd restart ||
            as_root rc-service sshd start

    elif have service; then

        as_root service ssh restart ||
            as_root service sshd restart

    else

        die "Could not determine how to start sshd."

    fi
}

# ------------------------------------------------------------
# macOS sshd
# ------------------------------------------------------------

remote_login_enabled() {
    as_root \
        launchctl print \
        system/com.openssh.sshd \
        >/dev/null 2>&1
}

enable_ssh_macos() {
    log "Enabling macOS Remote Login"

    # systemsetup can exit 0 without doing anything (it needs Full Disk
    # Access on recent macOS), so check the result instead of its status.
    as_root \
        /usr/sbin/systemsetup \
        -setremotelogin on \
        >/dev/null 2>&1 || true

    if remote_login_enabled; then
        return
    fi

    warn "systemsetup could not enable Remote Login."
    warn "Trying launchctl fallback."

    as_root \
        launchctl load \
        -w \
        /System/Library/LaunchDaemons/ssh.plist \
        >/dev/null 2>&1 || true

    if remote_login_enabled; then
        return
    fi

    # Common on a fresh Mac: without Full Disk Access neither method above
    # works, so have the person at the machine flip the switch, and wait.
    if (: </dev/tty) 2>/dev/null; then

        warn "macOS would not let this script turn on Remote Login."
        warn "Turn it on now: System Settings > General > Sharing > Remote Login"

        open 'x-apple.systempreferences:com.apple.Sharing-Settings.extension' \
            >/dev/null 2>&1 || true

        log "Waiting up to 5 minutes for Remote Login to be turned on"

        local i=0

        while [ "$i" -lt 150 ] && ! remote_login_enabled; do
            sleep 2
            i=$((i + 1))
        done

    fi

    remote_login_enabled ||
        die "Remote Login is off. Turn it on under System Settings > General > Sharing > Remote Login, then run this again."

    log "Remote Login is on"
}

# dsmemberutil resolves membership the same way sshd's SACL check does
# (by GUID, including nested groups), which matters for AD accounts.
ssh_access_member() {
    dsmemberutil checkmembership \
        -U "$TARGET_USER" \
        -G com.apple.access_ssh 2>/dev/null |
        grep -q 'is a member'
}

# Remote Login set to "Only these users" rejects anyone outside this group,
# even with a valid key. sshd logs it as "not in SACL" and the client just
# sees "Permission denied".
configure_macos_ssh_access() {
    # No group means Remote Login allows all users. Creating it would lock
    # everyone else out, so leave it alone.
    if ! dscl . -read /Groups/com.apple.access_ssh >/dev/null 2>&1; then
        log "Remote Login allows all users; no SSH access group to update"
        return
    fi

    if ssh_access_member; then
        log "$TARGET_USER already has SSH access"
        return
    fi

    log "Granting SSH access to $TARGET_USER"

    as_root dseditgroup \
        -o edit \
        -n /Local/Default \
        -a "$TARGET_USER" \
        -t user \
        com.apple.access_ssh || true

    as_root dscacheutil -flushcache || true

    # dseditgroup can fail to resolve Active Directory / mobile accounts.
    # Membership is checked by GUID, so write the GUID directly.
    if ! ssh_access_member; then

        local guid

        guid="$(
            dscl /Search -read "/Users/$TARGET_USER" GeneratedUID 2>/dev/null |
            sed -n 's/^GeneratedUID: //p' |
            head -n 1
        )"

        if [ -n "$guid" ]; then

            as_root dscl . -append \
                /Groups/com.apple.access_ssh \
                GroupMembership "$TARGET_USER" || true

            as_root dscl . -append \
                /Groups/com.apple.access_ssh \
                GroupMembers "$guid" || true

            as_root dscacheutil -flushcache || true

        fi

    fi

    # MDM profiles can block or revert this, so check instead of trusting
    # the exit status.
    ssh_access_member ||
        die "Could not add $TARGET_USER to com.apple.access_ssh. An MDM policy may be blocking it; add the account under System Settings > General > Sharing > Remote Login."

    # Jamf and other MDMs can rewrite this group later on a schedule.
    if [ -d /Library/Application\ Support/JAMF ] ||
       profiles status -type enrollment 2>/dev/null | grep -q 'MDM enrollment: Yes'
    then
        warn "This Mac is MDM-managed. If SSH access stops working later, a management policy may have reset Remote Login users."
    fi
}

# ------------------------------------------------------------
# Linux Tailscale
# ------------------------------------------------------------

install_tailscale_linux() {
    if have tailscale; then
        return
    fi

    log "Installing Tailscale"

    if have pacman; then

        as_root pacman \
            -S \
            --needed \
            --noconfirm \
            tailscale

    elif have apk; then

        as_root apk add tailscale

    else

        have curl ||
            die "curl is required"

        local installer

        installer="$(mktemp)"

        curl \
            -fsSL \
            https://tailscale.com/install.sh \
            -o "$installer"

        as_root sh "$installer"

        rm -f "$installer"

    fi
}

start_tailscaled_linux() {
    log "Enabling Tailscale at boot"

    if have systemctl; then

        as_root systemctl enable --now tailscaled

    elif have rc-update && have rc-service; then

        as_root rc-update add tailscaled default || true
        as_root rc-service tailscaled start

    else

        die "Could not start tailscaled."

    fi
}

# ------------------------------------------------------------
# macOS Tailscale
# ------------------------------------------------------------

# Homebrew is often missing from PATH under sudo or a bare `curl | bash`.
# Only use it if the target user can write to it (shared Macs often have
# Homebrew owned by another account); otherwise use the official package.
find_brew() {
    local candidate
    local prefix

    for candidate in \
        "$(command -v brew 2>/dev/null || true)" \
        /opt/homebrew/bin/brew \
        /usr/local/bin/brew
    do
        [ -n "$candidate" ] && [ -x "$candidate" ] || continue

        prefix="$(as_target_user "$candidate" --prefix 2>/dev/null)" || continue

        if as_target_user test -w "$prefix/Cellar" 2>/dev/null ||
           as_target_user test -w "$prefix" 2>/dev/null
        then
            printf '%s\n' "$candidate"
            return
        fi

        warn "Homebrew at $prefix is not writable by $TARGET_USER; not using it."
    done
}

# Homebrew refuses to run as root, so drop to the target user if needed.
as_target_user() {
    if [ "$(id -u)" -eq 0 ]; then
        sudo -u "$TARGET_USER" -H "$@"
    else
        "$@"
    fi
}

wait_for_tailscaled() {
    local i=0

    while [ "$i" -lt 15 ]; do
        "$TS_CMD" status >/dev/null 2>&1 && return
        "$TS_CMD" status 2>&1 | grep -qi 'logged out\|NeedsLogin' && return
        sleep 1
        i=$((i + 1))
    done

    warn "tailscaled did not respond within 15 seconds."
}

install_tailscale_macos() {

    #
    # Existing GUI install
    #

    if [ -x /Applications/Tailscale.app/Contents/MacOS/Tailscale ]; then

        TS_MODE='app'
        TS_CMD='/Applications/Tailscale.app/Contents/MacOS/Tailscale'

        return

    fi

    #
    # If Homebrew exists, use CLI-only tailscaled.
    # This is preferable for a server-style Mac.
    #

    local brew_bin

    brew_bin="$(find_brew)"

    if [ -n "$brew_bin" ]; then

        log "Installing CLI-only Tailscale using Homebrew"

        local brew_prefix

        brew_prefix="$(as_target_user "$brew_bin" --prefix)"

        as_target_user "$brew_bin" install tailscale

        TS_MODE='daemon'
        TS_CMD="$brew_prefix/bin/tailscale"

        # Homebrew's own service, or one installed by an earlier run.
        if as_root launchctl print system/homebrew.mxcl.tailscale >/dev/null 2>&1 ||
           as_root launchctl print system/com.tailscale.tailscaled >/dev/null 2>&1
        then
            log "tailscaled is already running"
        else
            # Tailscale's documented way to run the CLI daemon at boot.
            # Avoids `sudo brew services`, which newer Homebrew discourages.
            as_root "$brew_prefix/bin/tailscaled" install-system-daemon
        fi

        wait_for_tailscaled

        return

    fi

    #
    # Otherwise install official standalone app.
    #

    log "Installing official Tailscale macOS package"

    have curl ||
        die "curl is required"

    local page
    local pkg_name
    local pkg_dir
    local pkg_path

    page="$(
        curl \
            -fsSL \
            https://pkgs.tailscale.com/stable/
    )"

    pkg_name="$(
        printf '%s' "$page" |
        grep -oE 'Tailscale-[0-9.]+-macos\.pkg' |
        head -n 1
    )"

    [ -n "$pkg_name" ] ||
        die "Could not determine current Tailscale package."

    pkg_dir="$(mktemp -d)"
    pkg_path="$pkg_dir/$pkg_name"

    curl \
        -fL \
        "https://pkgs.tailscale.com/stable/$pkg_name" \
        -o "$pkg_path"

    as_root installer \
        -pkg "$pkg_path" \
        -target /

    rm -rf "$pkg_dir"

    warn "The Tailscale app may ask you to allow its network extension."
    warn "Approve it in System Settings if prompted, or 'tailscale up' will not connect."

    TS_MODE='app'
    TS_CMD='/Applications/Tailscale.app/Contents/MacOS/Tailscale'

    open -a Tailscale || true

    sleep 2
}

# ------------------------------------------------------------
# Cross-platform Tailscale wrapper
# ------------------------------------------------------------

ts() {
    if [ "$PLATFORM" = 'macos' ] &&
       [ "${TS_MODE:-}" = 'app' ]
    then

        TAILSCALE_BE_CLI=1 \
            "$TS_CMD" \
            "$@"

    else

        "$TS_CMD" "$@"

    fi
}

tailscale_is_running() {
    ts status --json 2>/dev/null |
        grep -Eq \
        '"BackendState"[[:space:]]*:[[:space:]]*"Running"'
}

connect_tailscale() {

    if tailscale_is_running; then
        log "Tailscale is already connected"
        return
    fi

    log "Connecting machine to Tailscale"

    #
    # Optional unattended auth.
    #
    # Never put TS_AUTH_KEY in this repository.
    #

    if [ -n "${TS_AUTH_KEY:-}" ]; then

        local key_file

        key_file="$(mktemp)"

        chmod 600 "$key_file"

        printf '%s' \
            "$TS_AUTH_KEY" \
            > "$key_file"

        if [ "${TS_MODE:-}" = 'daemon' ]; then

            as_root \
                "$TS_CMD" \
                up \
                --auth-key="file:$key_file"

        else

            ts up \
                --auth-key="file:$key_file"

        fi

        rm -f "$key_file"

    else

        #
        # Interactive login.
        # tailscale up will display/open the login flow.
        #

        if [ "${TS_MODE:-}" = 'daemon' ]; then

            as_root "$TS_CMD" up

        else

            ts up

        fi

    fi
}

# ------------------------------------------------------------
# Rex
# ------------------------------------------------------------

# Rex looks for ~/.local/bin/rex when it connects over SSH, so rex does not
# need to be on the PATH of a non-interactive login.
REX_BIN="$TARGET_HOME/.local/bin/rex"
REX_AGENT="$TARGET_HOME/Library/LaunchAgents/com.superlogical.rex.server-start.plist"
REX_VERSION=''

install_rex_linux() {
    local installer
    local rc=0

    log "Installing Rex"

    installer="$(mktemp)"

    curl -fsSL https://pkgs.superlogical.com/rex/install.sh -o "$installer" || rc=1

    if [ "$rc" -eq 0 ]; then
        # mktemp makes it 0600, and the target user may not be the one running this.
        chmod 644 "$installer"

        # --user installs into ~/.local/bin and, with systemd, runs
        # `rex server install` so the server starts at boot.
        as_target_user sh "$installer" --user </dev/null || rc=1
    fi

    rm -f "$installer"

    return "$rc"
}

install_rex_macos() {
    local arch
    local channel
    local release=''
    local pick
    local url
    local sha
    local dir
    local rc=0

    have jq || {
        warn "jq is missing (macOS 15 and later include it)."
        return 1
    }

    case "$(uname -m)" in
        arm64) arch='arm64' ;;
        *) arch='amd64' ;;
    esac

    # There is no stable release yet. Fall back to preview, as Rex's own
    # Linux installer does.
    for channel in stable preview; do
        release="$(curl -fsSL "https://blob.superlogical.com/api/releases/rex/$channel" 2>/dev/null)" && break
        release=''
    done

    # The standalone binary. The one inside Rex.app is tied to the app's
    # Info.plist and macOS kills it when it is copied out on its own.
    pick='first(.artifacts[] | select(.os == "darwin" and .arch == $arch and (.filename | endswith(".zip"))))'

    url="$(printf '%s' "$release" | jq -er --arg arch "$arch" "$pick | .downloadUrl")" &&
    sha="$(printf '%s' "$release" | jq -er --arg arch "$arch" "$pick | .sha256")" || {
        warn "Could not find a Rex release for macOS $arch."
        return 1
    }

    log "Installing Rex ($channel channel)"

    dir="$(mktemp -d)"

    if curl -fsSL "$url" -o "$dir/rex.zip" &&
       printf '%s  %s\n' "$sha" "$dir/rex.zip" | shasum -a 256 -c - >/dev/null &&
       unzip -q "$dir/rex.zip" rex -d "$dir"
    then
        # rm first: an older manual install may have left a symlink here.
        as_target_user mkdir -p "$TARGET_HOME/.local/bin" &&
        as_root rm -f "$REX_BIN" &&
        as_root install -m 755 -o "$TARGET_USER" -g "$TARGET_GROUP" "$dir/rex" "$REX_BIN" ||
            rc=1
    else
        warn "Downloading or verifying Rex failed."
        rc=1
    fi

    rm -rf "$dir"

    [ "$rc" -eq 0 ] || return 1

    # `rex server install` does not support macOS yet. Start the server now,
    # and again at every login. After a reboot it is down until someone logs in.
    log "Starting the Rex server (and at every login)"

    as_target_user mkdir -p "$TARGET_HOME/Library/LaunchAgents" || return 1

    # AbandonProcessGroup: `rex server start` leaves the server running in
    # the background, and launchd would otherwise kill it when the job exits.
    as_target_user tee "$REX_AGENT" >/dev/null <<EOF || return 1
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.superlogical.rex.server-start</string>
    <key>ProgramArguments</key>
    <array>
        <string>$REX_BIN</string>
        <string>server</string>
        <string>start</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>AbandonProcessGroup</key>
    <true/>
</dict>
</plist>
EOF

    as_target_user "$REX_BIN" server start >/dev/null
}

install_rex() {
    if [ "$PLATFORM" = 'linux' ]; then
        install_rex_linux || return 1
    else
        install_rex_macos || return 1
    fi

    REX_VERSION="$(as_target_user "$REX_BIN" version 2>/dev/null | head -n 1)"

    [ -n "$REX_VERSION" ]
}

# ------------------------------------------------------------
# Result
# ------------------------------------------------------------

SELF_TEST_DIR=''
SELF_TEST_BLOB=''
SELF_TEST_ERROR=''

cleanup_self_test() {
    if [ -n "$SELF_TEST_BLOB" ]; then
        rewrite_authorized_keys "$SELF_TEST_BLOB" || true
        SELF_TEST_BLOB=''
    fi

    if [ -n "$SELF_TEST_DIR" ]; then
        rm -rf "$SELF_TEST_DIR"
        SELF_TEST_DIR=''
    fi
}

# Log in over Tailscale with a throwaway key, restricted exactly like the
# team key, so "complete" means a teammate's login will actually work:
# sshd running, Remote Login access group, authorized_keys permissions and
# the Tailscale-only source restriction are all exercised.
self_test_ssh() {
    local ts_ip="$1"
    local output

    trap cleanup_self_test EXIT
    trap 'cleanup_self_test; exit 130' INT TERM

    SELF_TEST_DIR="$(mktemp -d)"

    # Called inside `if`, where set -e is off, so check each step.
    if ! ssh-keygen -q -t ed25519 -N '' \
        -C 'team-bootstrap-selftest' \
        -f "$SELF_TEST_DIR/key"
    then
        cleanup_self_test
        trap - EXIT INT TERM
        SELF_TEST_ERROR='could not create a test key'
        return 1
    fi

    SELF_TEST_BLOB="$(awk '{print $2}' "$SELF_TEST_DIR/key.pub")"

    rewrite_authorized_keys \
        "$SELF_TEST_BLOB" \
        "from=\"${TAILSCALE_V4},${TAILSCALE_V6}\",restrict,command=\"echo team-bootstrap-ok\" $(cat "$SELF_TEST_DIR/key.pub")"

    output="$(
        ssh \
            -F /dev/null \
            -i "$SELF_TEST_DIR/key" \
            -o IdentitiesOnly=yes \
            -o BatchMode=yes \
            -o ConnectTimeout=10 \
            -o StrictHostKeyChecking=no \
            -o UserKnownHostsFile=/dev/null \
            -o GlobalKnownHostsFile=/dev/null \
            -o LogLevel=ERROR \
            "$TARGET_USER@$ts_ip" 2>&1
    )" || true

    cleanup_self_test

    trap - EXIT INT TERM

    case "$output" in
        *team-bootstrap-ok*)
            return 0
            ;;
    esac

    SELF_TEST_ERROR="${output:-no output}"

    return 1
}

show_result() {

    local ts_ip
    local ts_name
    local alias_name
    local problem=''

    ts_ip="$(
        ts ip -4 2>/dev/null |
        head -n 1 ||
        true
    )"

    ts_name="$(
        ts status --json --peers=false 2>/dev/null |
        sed -n 's/^ *"DNSName": "\([^"]*\)\.",*$/\1/p' |
        head -n 1 ||
        true
    )"

    alias_name="${ts_name%%.*}"
    alias_name="${alias_name:-$(hostname -s | tr '[:upper:]' '[:lower:]')}"

    if [ -z "$ts_ip" ] || ! tailscale_is_running; then

        problem='Tailscale is not connected. Finish the Tailscale login, then run this script again.'

    elif ! have ssh; then

        warn "No ssh client on this machine; skipping the login self-test."

    else

        log "Testing an SSH login over Tailscale"

        if ! self_test_ssh "$ts_ip"; then
            problem="A test SSH login over Tailscale failed: $SELF_TEST_ERROR"
        fi

    fi

    printf '\n'
    printf '============================================================\n'

    if [ -n "$problem" ]; then
        printf ' SERVER BOOTSTRAP NOT READY\n'
    else
        printf ' SERVER BOOTSTRAP COMPLETE\n'
    fi

    printf '============================================================\n'
    printf 'OS:             %s\n' "$PLATFORM"
    printf 'SSH user:       %s\n' "$TARGET_USER"
    printf 'Tailscale IPv4: %s\n' "${ts_ip:-unavailable}"
    printf 'Tailscale name: %s\n' "${ts_name:-unavailable}"
    printf '\n'

    if [ -n "$problem" ]; then
        printf 'ERROR: %s\n' "$problem" >&2
        exit 1
    fi

    printf 'Verified: a test login over Tailscale succeeded.\n'
    printf 'SSH password authentication is disabled.\n'
    printf 'Team SSH key is restricted to Tailscale source addresses.\n'
    printf '\n'
    printf 'On the computer you connect from (it must be signed in to\n'
    printf 'Tailscale and have the team key), add to ~/.ssh/config:\n'
    printf '\n'
    printf 'Host %s\n' "$alias_name"
    printf '    HostName %s\n' "$ts_ip"
    printf '    User %s\n' "$TARGET_USER"
    printf '    IdentityFile ~/.ssh/colmena_hetzner\n'
    printf '    IdentitiesOnly yes\n'
    printf '\n'
    printf 'Then connect with:\n\n'
    printf '  ssh %s\n\n' "$alias_name"

    if [ -n "$REX_VERSION" ]; then
        printf 'Rex is installed (%s). To use this machine as a Rex\n' "$REX_VERSION"
        printf 'remote host, run this on the computer you connect from:\n\n'
        printf '  rex hosts add %s ssh://%s\n\n' "$alias_name" "$alias_name"
    fi
}

# ------------------------------------------------------------
# Main
#
# Everything runs from main(), called on the last line, so that with
# `curl | bash` the whole script is read before any step runs. Otherwise
# a command that reads stdin could swallow the rest of the script.
# ------------------------------------------------------------

main() {

    if [ "$PLATFORM" = 'linux' ]; then

        install_openssh_linux

        install_authorized_key
        configure_sshd_key_only
        start_sshd_linux

        install_tailscale_linux

        TS_MODE='daemon'
        TS_CMD="$(command -v tailscale)"

        start_tailscaled_linux
        connect_tailscale

    else

        install_authorized_key
        configure_sshd_key_only
        enable_ssh_macos
        configure_macos_ssh_access

        install_tailscale_macos
        connect_tailscale

    fi

    # Optional extra: SSH works without it, so a failure only warns.
    install_rex ||
        warn "Rex could not be installed. SSH still works; install Rex by hand later."

    show_result
}

main "$@"
