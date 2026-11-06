#!/bin/zsh -f
# Guest service (root, LaunchDaemon: at boot, every 60 s and when /Library/Managed Preferences changes):
#   - puts the Chrome policies for the account back: macOS removes them at every login (without MDM nothing stays
#     there). The policies make sign-ins expire: cookies and site data only for the session except the allowed
#     domains, history, cache and download list cleared when Chrome quits, no session restore,
#   - keeps macOS' list of apps to reopen at login empty and locked: loginwindow writes it at shutdown from its memory
#     (even with "reopen windows" off), so it would reopen Chrome at every login, before its policies are back,
#   - once per boot moves the content of ~/Downloads into a folder in the account's Trash (the Finder empties it after
#     30 days). At boot no Chrome is running yet.
set -u
source /usr/local/libexec/annex/settings.env   # GUEST_USER LIBEXEC LOG
MANAGED="/Library/Managed Preferences"
MARKER=/var/db/annex-guest-boot
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

note() { print -r -- "$(date '+%Y-%m-%d %H:%M:%S') service: $*" >> "$LOG"; }
cd /
id -u "$GUEST_USER" >/dev/null 2>&1 || exit 0
[ -f "$LIBEXEC/chrome.plist" ] || { note "chrome.plist missing"; exit 1; }

zmodload zsh/parameter
TALD="${userdirs[$GUEST_USER]:-/nonexistent}/Library/Group Containers/group.com.apple.loginwindow.persistent-apps"
TAL="$TALD/persistantApps"   # sic
# Only root can change the locked file (owner root, flag uchg). The new one is written in a root-only place and moved
# in: a link planted in the account's folder is replaced, not followed.
if [ -d "$TALD" ] && [ ! -L "$TALD" ] && [ ! -d "$TAL" ] && [ "$(stat -f '%u %Sf' "$TAL" 2>/dev/null)" != "0 uchg" ]; then
  t="$(mktemp /var/db/annex-tal.XXXXXX)" && print -r -- '<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>PersistentApps</key><array/></dict></plist>' > "$t" && chmod 644 "$t" && {
    chflags -h nouchg "$TAL" 2>/dev/null
    mv -f "$t" "$TAL" && chflags -h uchg "$TAL" && note "list of apps to reopen at login locked empty"
  }
  rm -f "$t" 2>/dev/null
fi

f="$MANAGED/$GUEST_USER/com.google.Chrome.plist"
if ! { [ -f "$f" ] && [ ! -L "$f" ] && cmp -s "$LIBEXEC/chrome.plist" "$f"; }; then
  install -d -m 755 -o root -g wheel "$MANAGED" "$MANAGED/$GUEST_USER"
  rm -f "$f"
  install -m 644 -o root -g wheel "$LIBEXEC/chrome.plist" "$f" && note "policies placed"
fi

# Once per boot. The marker is written before cleaning up, so an error does not repeat the cleanup every 60 s
# (maybe in the middle of a task).
boot="$(sysctl -n kern.boottime)"
[ "$(cat "$MARKER" 2>/dev/null)" = "$boot" ] && exit 0
print -r -- "$boot" > "$MARKER"
# As the account, not as root: root would follow links planted in its folder.
n="$(/usr/bin/sudo -u "$GUEST_USER" -H /bin/zsh -f -c '
  d="$HOME/Downloads"
  [ -d "$d" ] && [ ! -L "$d" ] || { print 0; exit 0; }
  items=()
  for x in "$d"/*(DN); do [ "${x:t}" = .localized ] || items+=("$x"); done
  (( ${#items} )) || { print 0; exit 0; }
  t="$HOME/.Trash"
  [ -d "$t" ] || /bin/mkdir -m 700 "$t" || exit 1
  z="$t/Downloads $(date "+%Y-%m-%d %H.%M.%S")"
  /bin/mkdir "$z" && /bin/mv -- "${items[@]}" "$z/" && print ${#items}' 2>>"$LOG")" \
  || { note "downloads not cleaned up"; exit 1; }
[ "$n" = 0 ] || note "downloads: $n items moved to the Trash"
exit 0
