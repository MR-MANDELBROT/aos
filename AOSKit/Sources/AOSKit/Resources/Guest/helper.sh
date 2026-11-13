#!/bin/zsh -f
# Installs the workspace helper (root, from setup.sh and update.sh; kit folder $1): AOSHelper.app from
# AOSHelper.tgz into $LIBEXEC, checked against aOS's signature, and a LaunchAgent that runs it in the account's
# session. It needs the Accessibility permission (the user switches it on once, aOS shows how); with it, it tells
# aOS which sign-in field has the focus and types approved sign-ins into exactly that page.
# Without AOSHelper.tgz in the kit (development builds) nothing happens.
set -eu
K="${1:?kit folder missing}"
source "$K/settings.env"   # GUEST_USER LIBEXEC LOG
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
die() { print -r -- "ERROR: $*" >&2; exit 1; }
[ -s "$K/AOSHelper.tgz" ] || exit 0

LABEL=dev.marquart.aos.guest-helper
REQ='anchor apple generic and identifier "dev.marquart.aos.guest-helper" and certificate leaf[subject.OU] = "S3725YB7V6"'
PLIST="/Library/LaunchAgents/$LABEL.plist"

T="$(mktemp -d /var/root/aos-helper.XXXXXX)"
trap 'rm -rf "$T"' EXIT
tar -xzf "$K/AOSHelper.tgz" -C "$T"
[ -d "$T/AOSHelper.app" ] || die "AOSHelper.app missing in the archive"
codesign --verify --strict -R="$REQ" "$T/AOSHelper.app" || die "the helper is not signed by aOS"

UID_G="$(id -u "$GUEST_USER")"
logged_in() { [ "$(stat -f %Su /dev/console)" = "$GUEST_USER" ]; }
# Bootstrapping right after a bootout often fails while launchd still removes the old instance ("Bootstrap failed:
# 5"), and then no helper ran until the next login (measured with build 21): so wait, retry, and say if it didn't.
ensure_running() {
  logged_in || return 0
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    launchctl print "gui/$UID_G/$LABEL" >/dev/null 2>&1 && return 0
    launchctl bootstrap "gui/$UID_G" "$PLIST" 2>/dev/null || true
    sleep 1
  done
  launchctl print "gui/$UID_G/$LABEL" >/dev/null 2>&1 && return 0
  print -r -- "$(date '+%Y-%m-%d %H:%M:%S') helper did not start" >> "$LOG"
  print -r -- "WARNING: the helper did not start; it starts at the next login" >&2
}
# Waits until launchd has let go of the old instance.
gone() {
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    launchctl print "gui/$UID_G/$LABEL" >/dev/null 2>&1 || return 0
    sleep 0.5
  done
}
# Owned by root, readable and runnable by the account (the kit unpacks with umask 077; older setups also created
# /usr/local/libexec itself as 0700, which the account can't pass)
own() {
  chmod 755 "$(dirname "$LIBEXEC")" "$LIBEXEC"
  chown -R root:wheel "$LIBEXEC/AOSHelper.app"
  chmod -R u=rwX,go=rX "$LIBEXEC/AOSHelper.app"
}
# Same version already installed: keep it (and its running process)
if [ -d "$LIBEXEC/AOSHelper.app" ] && diff -rq "$T/AOSHelper.app" "$LIBEXEC/AOSHelper.app" >/dev/null 2>&1 \
   && [ -f "$PLIST" ]; then
  own
  ensure_running
  exit 0
fi
launchctl bootout "gui/$UID_G/$LABEL" 2>/dev/null || true
gone
rm -rf "$LIBEXEC/AOSHelper.app"
mv "$T/AOSHelper.app" "$LIBEXEC/AOSHelper.app"
own

cat > "$PLIST.new" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key><string>$LABEL</string>
	<key>ProgramArguments</key><array><string>$LIBEXEC/AOSHelper.app/Contents/MacOS/AOSHelper</string><string>serve</string></array>
	<key>RunAtLoad</key><true/>
	<key>KeepAlive</key><true/>
	<key>LimitLoadToSessionType</key><string>Aqua</string>
	<key>ProcessType</key><string>Interactive</string>
</dict>
</plist>
EOF
chown root:wheel "$PLIST.new"
chmod 644 "$PLIST.new"
plutil -lint "$PLIST.new" >/dev/null || die "helper plist invalid"
mv -f "$PLIST.new" "$PLIST"
# Running now if the account is logged in; otherwise launchd starts it at the next login.
ensure_running
print -r -- "$(date '+%Y-%m-%d %H:%M:%S') helper installed" >> "$LOG"
print -r -- "==> helper installed"
