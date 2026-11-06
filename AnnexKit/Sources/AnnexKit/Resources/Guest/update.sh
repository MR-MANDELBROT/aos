#!/bin/zsh -f
# Brings a set-up guest up to date (root, over the maintenance key): scripts and Chrome policies from the kit
# folder ($1). Keys, accounts and settings stay. The guest service puts the new policies in place within a minute
# and at the next login; Chrome reads them at its next start.
set -eu
K="${1:?kit folder missing}"
LIBEXEC=/usr/local/libexec/annex
die() { print -r -- "ERROR: $*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || die "must run as root"
for f in guest-service.sh shutdown.sh finish.sh prepare.sh helper.sh update.sh; do
  [ -s "$K/$f" ] || die "$f missing"
  zsh -n "$K/$f" || die "$f has a syntax error"
  install -m 755 -o root -g wheel "$K/$f" "$LIBEXEC/$f"
done
plutil -lint "$K/chrome.plist" >/dev/null || die "chrome.plist invalid"
install -m 644 -o root -g wheel "$K/chrome.plist" "$LIBEXEC/chrome.plist"
install -m 644 -o root -g wheel "$K/settings.env" "$LIBEXEC/settings.env"
# A workspace whose account is a standard user already went through finish.sh (older ones had no marker).
GU="$(source "$K/settings.env"; print -r -- "$GUEST_USER")"
if ! dseditgroup -o checkmember -m "$GU" admin 2>/dev/null | grep -q '^yes'; then
  touch /var/db/annex-finished
fi
zsh -f "$LIBEXEC/helper.sh" "$K"
print -r -- "==> workspace updated"
