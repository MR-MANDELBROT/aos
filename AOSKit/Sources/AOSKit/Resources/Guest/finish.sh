#!/bin/zsh -f
# Last setup step (root, over the maintenance key), after screen sharing works: the account becomes a standard user,
# so whoever operates the screen can't change Chrome, the policies or these scripts. Maintenance continues as root
# with the host's key. Also checks that only screen sharing and SSH are on.
set -eu
source /usr/local/libexec/aos/settings.env   # GUEST_USER
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
die() { print -r -- "ERROR: $*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "must run as root"
launchctl print-disabled system | grep -q '"com.apple.screensharing" => enabled' || die "screen sharing is off"
for s in com.apple.smbd com.apple.AppleFileServer com.apple.ftp-proxy com.apple.AEServer com.apple.InternetSharing \
         com.apple.RemoteDesktop.agent com.apple.ARDAgent; do
  if launchctl print-disabled system | grep -q "\"$s\" => enabled"; then die "$s is on; only screen sharing may be"; fi
done
# Screen sharing only for the account
for u in $(dscl . -read /Groups/com.apple.access_screensharing GroupMembership 2>/dev/null | cut -d: -f2-); do
  [ "$u" = "$GUEST_USER" ] || dseditgroup -o edit -d "$u" -t user com.apple.access_screensharing
done
dseditgroup -o edit -d "$GUEST_USER" -t user admin 2>/dev/null || true
if dseditgroup -o checkmember -m "$GUEST_USER" admin 2>/dev/null | grep -q '^yes'; then die "$GUEST_USER is still an administrator"; fi
print -r -- "==> $GUEST_USER is a standard user"
# Marks the workspace as finished: prepare.sh makes the account a standard user again should it still be an
# administrator (after the one-time permission for the helper, see Provisioner.beginHelperPermission).
touch /var/db/aos-finished
