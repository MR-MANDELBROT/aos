#!/bin/zsh -f
# Prepares the guest. Runs as root INSIDE the VM, once after the first boot (the bootstrap unpacks the kit into a
# temporary folder and passes its path). The first boot already created the account (macOS 27 guest provisioning:
# administrator, automatic login, SSH on, no Setup Assistant). This script
#   - lets only root log in over SSH, and only with the host's keys: the maintenance key may run anything, the stop
#     key only the orderly shutdown,
#   - installs the guest service (Chrome policies after every login, downloads to the Trash once per boot) and the
#     shutdown script,
#   - turns off sleep, screen saver and screen lock, automatic macOS updates; sets language, region, time zone like
#     the host and the ABC keyboard layout (the VNC client sends key symbols that need a predictable layout),
#   - installs Google Chrome (Google's signed enterprise package) with the managed policies,
#   - allows screen sharing for the account only. Turning screen sharing on is a separate, guided step: macOS only
#     delivers a picture when a person switched it on in System Settings.
# The account stays an administrator until screen sharing works; `finish.sh` then makes it a standard user.
#
# Kit folder ($1): maintenance.pub, stop.pub, chrome.plist, settings.env, guest-service.sh, shutdown.sh, finish.sh, prepare.sh,
# update.sh
set -eu
setopt NULL_GLOB

K="${1:?kit folder missing}"
source "$K/settings.env"   # GUEST_USER LIBEXEC SERVICE_LABEL LOG LANGUAGES LOCALE TIMEZONE
CHROME_REQ='anchor apple generic and identifier "com.google.Chrome" and certificate leaf[subject.OU] = "EQHXZ8M8AV"'
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

say() { print -r -- "==> $*"; }
die() { print -r -- "ERROR: $*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "must run as root"
for f in maintenance.pub stop.pub chrome.plist settings.env guest-service.sh shutdown.sh finish.sh prepare.sh helper.sh update.sh; do
  [ -s "$K/$f" ] || die "$f missing"
done
id "$GUEST_USER" >/dev/null 2>&1 || die "account $GUEST_USER missing (first boot without provisioning?)"
UID_G="$(id -u "$GUEST_USER")"
as_user() { launchctl asuser "$UID_G" sudo -u "$GUEST_USER" -H "$@"; }

# Scripts
install -d -m 755 -o root -g wheel "$(dirname "$LIBEXEC")" "$LIBEXEC"
for f in guest-service.sh shutdown.sh finish.sh prepare.sh helper.sh update.sh; do
  zsh -n "$K/$f" || die "$f has a syntax error"
  install -m 755 -o root -g wheel "$K/$f" "$LIBEXEC/$f"
done
plutil -lint "$K/chrome.plist" >/dev/null || die "chrome.plist invalid"
install -m 644 -o root -g wheel "$K/chrome.plist" "$LIBEXEC/chrome.plist"
install -m 644 -o root -g wheel "$K/settings.env" "$LIBEXEC/settings.env"
say "scripts in $LIBEXEC"

# SSH: root with the host's keys only. sshd reads its settings for every connection (launchd starts one each).
install -d -m 700 -o root -g wheel /var/root/.ssh
{
  print -r -- "restrict $(<"$K/maintenance.pub")"
  print -r -- "restrict,command=\"$LIBEXEC/shutdown.sh\" $(<"$K/stop.pub")"
} > /var/root/.ssh/authorized_keys.new
[ "$(wc -l < /var/root/.ssh/authorized_keys.new | tr -d ' ')" = 2 ] || die "a public key contains a line break"
chown root:wheel /var/root/.ssh/authorized_keys.new
chmod 600 /var/root/.ssh/authorized_keys.new
mv -f /var/root/.ssh/authorized_keys.new /var/root/.ssh/authorized_keys
if dseditgroup -o read com.apple.access_ssh >/dev/null 2>&1; then
  dseditgroup -o edit -a root -t user com.apple.access_ssh
fi
cat > /etc/ssh/sshd_config.d/010-aos.conf <<'EOF'
# Workspace VM: root with the host's keys only; authorized_keys decides what each key may run.
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
AllowUsers root
EOF
chmod 644 /etc/ssh/sshd_config.d/010-aos.conf
sshd -t || die "sshd settings invalid"
say "SSH: root with keys only"

# Screen sharing only for the account (switched on later, see above)
dseditgroup -o read com.apple.access_screensharing >/dev/null 2>&1 \
  || dseditgroup -o create -r "Screen Sharing ACL" com.apple.access_screensharing
dseditgroup -o edit -a "$GUEST_USER" -t user com.apple.access_screensharing
say "screen sharing allowed for $GUEST_USER"

# No sleep, no screen saver, no lock: the session is only reachable over VNC
pmset -a sleep 0 displaysleep 0 disksleep 0 powernap 0 >/dev/null 2>&1 || true
as_user defaults -currentHost write com.apple.screensaver idleTime -int 0
as_user defaults write com.apple.screensaver askForPassword -int 0
as_user defaults write com.apple.screensaver askForPasswordDelay -int 0
# macOS should not reopen apps at login (Chrome would start before its policies are back)
as_user defaults write com.apple.loginwindow TALLogoutSavesState -bool false
as_user defaults write com.apple.loginwindow LoginwindowLaunchesRelaunchApps -bool false
as_user defaults write com.apple.finder FXRemoveOldTrashItems -bool true
say "no sleep, no screen saver, no relaunch at login"

# Language and region like the host, ABC keyboard, host time zone
if [ -n "${LANGUAGES:-}" ]; then
  as_user defaults write -g AppleLanguages -array ${=LANGUAGES}
  # Also for the system: the account's first login may copy the system's list over the account's (prepare.sh
  # puts it right after every boot).
  defaults write /Library/Preferences/.GlobalPreferences AppleLanguages -array ${=LANGUAGES}
fi
[ -n "${LOCALE:-}" ] && as_user defaults write -g AppleLocale -string "$LOCALE"
LAYOUT='{ InputSourceKind = "Keyboard Layout"; "KeyboardLayout ID" = 252; "KeyboardLayout Name" = ABC; }'
as_user defaults write com.apple.HIToolbox AppleEnabledInputSources -array "$LAYOUT"
as_user defaults write com.apple.HIToolbox AppleSelectedInputSources -array "$LAYOUT"
as_user defaults write com.apple.HIToolbox AppleCurrentKeyboardLayoutInputSourceID -string com.apple.keylayout.ABC
[ -n "${TIMEZONE:-}" ] && { systemsetup -settimezone "$TIMEZONE" >/dev/null 2>&1 || true; }
say "language ${LANGUAGES:-default}, keyboard ABC, time zone ${TIMEZONE:-default}"

# No automatic macOS updates (a restart in the middle of a task); security data stays on
defaults write /Library/Preferences/com.apple.SoftwareUpdate AutomaticallyInstallMacOSUpdates -bool false
defaults write /Library/Preferences/com.apple.SoftwareUpdate AutomaticDownload -bool false
defaults write /Library/Preferences/com.apple.SoftwareUpdate ConfigDataInstall -bool true
defaults write /Library/Preferences/com.apple.SoftwareUpdate CriticalUpdateInstall -bool true
say "no automatic macOS updates"

# Google Chrome from Google's enterprise package (signature of package and app checked)
if ! codesign --verify --deep --strict -R="$CHROME_REQ" "/Applications/Google Chrome.app" >/dev/null 2>&1; then
  PKG="$K/GoogleChrome.pkg"
  curl -fsSL --retry 3 -o "$PKG" "https://dl.google.com/chrome/mac/universal/stable/gcem/GoogleChrome.pkg" \
    || die "could not download Chrome"
  SIG="$(pkgutil --check-signature "$PKG" 2>&1)" || die "Chrome package is not signed"
  print -r -- "$SIG" | grep -q "Developer ID Installer: Google LLC (EQHXZ8M8AV)" || die "Chrome package is not from Google"
  installer -pkg "$PKG" -target / >/dev/null || die "Chrome installation failed"
  rm -f "$PKG"
fi
codesign --verify --deep --strict -R="$CHROME_REQ" "/Applications/Google Chrome.app" || die "Chrome signature wrong"
say "Chrome $(defaults read "/Applications/Google Chrome.app/Contents/Info" CFBundleShortVersionString)"
# Chrome into the Dock (the agent is told it is there)
if ! as_user defaults read com.apple.dock persistent-apps 2>/dev/null | grep -q "Google Chrome.app"; then
  as_user defaults write com.apple.dock persistent-apps -array-add \
    '<dict><key>tile-data</key><dict><key>file-data</key><dict><key>_CFURLString</key><string>file:///Applications/Google%20Chrome.app/</string><key>_CFURLStringType</key><integer>15</integer></dict></dict></dict>'
  as_user killall Dock 2>/dev/null || true
fi

# Guest service: puts the Chrome policies back after every login (macOS clears /Library/Managed Preferences without
# MDM), moves old downloads to the Trash once per boot
cat > "/Library/LaunchDaemons/$SERVICE_LABEL.plist.new" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key><string>$SERVICE_LABEL</string>
	<key>ProgramArguments</key><array><string>/bin/zsh</string><string>-f</string><string>$LIBEXEC/guest-service.sh</string></array>
	<key>RunAtLoad</key><true/>
	<key>StartInterval</key><integer>60</integer>
	<key>WatchPaths</key><array><string>/Library/Managed Preferences</string><string>/Library/Managed Preferences/$GUEST_USER</string></array>
	<key>StandardOutPath</key><string>/dev/null</string>
	<key>StandardErrorPath</key><string>$LOG</string>
</dict>
</plist>
EOF
chown root:wheel "/Library/LaunchDaemons/$SERVICE_LABEL.plist.new"
chmod 644 "/Library/LaunchDaemons/$SERVICE_LABEL.plist.new"
plutil -lint "/Library/LaunchDaemons/$SERVICE_LABEL.plist.new" >/dev/null || die "service plist invalid"
launchctl bootout "system/$SERVICE_LABEL" 2>/dev/null || true
mv -f "/Library/LaunchDaemons/$SERVICE_LABEL.plist.new" "/Library/LaunchDaemons/$SERVICE_LABEL.plist"
launchctl bootstrap system "/Library/LaunchDaemons/$SERVICE_LABEL.plist" || die "guest service does not start"
P="/Library/Managed Preferences/$GUEST_USER/com.google.Chrome.plist"
for i in {1..30}; do cmp -s "$LIBEXEC/chrome.plist" "$P" 2>/dev/null && break; sleep 1; done
cmp -s "$LIBEXEC/chrome.plist" "$P" || die "the guest service does not place the Chrome policies"
say "guest service running, Chrome policies in place"
zsh -f "$LIBEXEC/helper.sh" "$K" || die "the workspace helper could not be installed"
say "done"
