#!/bin/zsh -f
# Before the agent gets the screen for the first time after a boot (root, over the maintenance key, run by the host):
#   - waits until the account is logged in: macOS removes /Library/Managed Preferences at the login, and right after
#     it the guest is so busy that the guest service needs up to half a minute to put the Chrome policies back,
#   - puts them back now and checks that they are in place,
#   - quits a Chrome that macOS reopened at the login (before the policies were back, so without them: it would
#     ask for a search engine and keep site data). Nobody has used it yet; the agent starts a fresh one.
# Prints "ok" or a reason, exit status 0 only when the policies are in place.
set -u
source /usr/local/libexec/annex/settings.env   # GUEST_USER LIBEXEC LOG
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
JXA='function run(a){ObjC.import("AppKit");return a.map(function(p){var x=$.NSRunningApplication.runningApplicationWithProcessIdentifier(parseInt(p,10));return p+":"+(x.isNil()?"gone":(x.terminate?"ok":"no"))}).join(" ")}'
note() { print -r -- "$(date '+%Y-%m-%d %H:%M:%S') prepare: $*" >> "$LOG"; }
cd /

for i in {1..240}; do [ "$(stat -f %Su /dev/console)" = "$GUEST_USER" ] && break; sleep 0.5; done
[ "$(stat -f %Su /dev/console)" = "$GUEST_USER" ] || { print "the account is not logged in"; exit 3; }
uid="$(id -u "$GUEST_USER")" || exit 3

# A finished workspace's account is a standard user (it may only have been an administrator for a moment to allow
# the helper; if that was interrupted, it ends here).
if [ -f /var/db/annex-finished ] && dseditgroup -o checkmember -m "$GUEST_USER" admin 2>/dev/null | grep -q '^yes'; then
  dseditgroup -o edit -d "$GUEST_USER" -t user admin && note "account is a standard user again"
fi

f="/Library/Managed Preferences/$GUEST_USER/com.google.Chrome.plist"
placed=0
for i in 1 2 3; do
  /bin/zsh -f "$LIBEXEC/guest-service.sh"
  sleep 1
  if [ -f "$f" ] && [ ! -L "$f" ] && cmp -s "$LIBEXEC/chrome.plist" "$f"; then placed=1; break; fi
done
(( placed )) || { note "policies not in place"; print "the browser policies are not in place"; exit 4; }

pids=($(pgrep -u "$uid" -x "Google Chrome" 2>/dev/null))
if (( ${#pids} )); then
  /bin/launchctl asuser "$uid" /usr/bin/sudo -u "$GUEST_USER" -- /usr/bin/osascript -l JavaScript -e "$JXA" \
    "${pids[@]}" >>"$LOG" 2>&1 &
  o=$!
  for i in {1..16}; do [ -z "$(pgrep -u "$uid" -x "Google Chrome")" ] && break; sleep 0.5; done
  kill "$o" 2>/dev/null
  rest=($(pgrep -u "$uid" -x "Google Chrome" 2>/dev/null))
  (( ${#rest} )) && kill -TERM "${rest[@]}" 2>/dev/null
  note "Chrome reopened at login without its policies, quit (${pids[*]})"
fi
print ok
