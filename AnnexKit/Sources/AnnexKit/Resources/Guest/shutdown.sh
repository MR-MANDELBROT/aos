#!/bin/zsh -f
# Orderly shutdown of the guest (root; the host's stop key may run nothing else). First every Chrome of the account
# quits through the "quit" Apple event (NSRunningApplication terminate, like Chrome > Quit; macOS does not ask for
# permission). Only then does Chrome clear the site data its policies ask for: SIGTERM and a hard power-off clear
# nothing. A Chrome that is still starting accepts the event and does not quit, so it is sent again every 3 s. A
# Chrome that has not quit after 25 s (e.g. "Leave site?") gets SIGTERM; the guest shuts down in any case.
set -u
source /usr/local/libexec/annex/settings.env   # GUEST_USER LOG
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
JXA='function run(a){ObjC.import("AppKit");return a.map(function(p){var x=$.NSRunningApplication.runningApplicationWithProcessIdentifier(parseInt(p,10));return p+":"+(x.isNil()?"gone":(x.terminate?"ok":"no"))}).join(" ")}'

note() { print -r -- "$(date '+%Y-%m-%d %H:%M:%S') shutdown: $*" >> "$LOG"; }
off() { note "powering off"; exec /sbin/shutdown -h now; }
cd /
uid="$(id -u "$GUEST_USER" 2>/dev/null)" || off
main_pids() { pgrep -u "$uid" -x "Google Chrome" 2>/dev/null; }

# In the account's launchd domain (where its apps run), as the account; give up on osascript after 10 s
quit_apps() {
  /bin/launchctl asuser "$uid" /usr/bin/sudo -u "$GUEST_USER" -- /usr/bin/osascript -l JavaScript -e "$JXA" "$@" \
    >>"$LOG" 2>&1 &
  local o=$!
  ( sleep 10; kill "$o" 2>/dev/null ) &
}

pids=($(main_pids))
(( ${#pids} )) || off
for i in {1..50}; do
  rest=($(main_pids))
  (( ${#rest} )) || break
  (( (i - 1) % 6 == 0 )) && quit_apps "${rest[@]}"
  sleep 0.5
done
rest=($(main_pids))
if (( ${#rest} )); then
  note "Chrome does not quit (${rest[*]}), SIGTERM; site data stays until the next orderly quit"
  kill -TERM "${rest[@]}" 2>/dev/null
  for i in {1..10}; do [ -z "$(main_pids)" ] && break; sleep 0.5; done
else
  note "Chrome quit in order (${pids[*]})"
fi
off
