#!/bin/zsh -f
# Signs the workspace out of every website (root, over the maintenance key, run by the host when the person asks:
# the Mac app's "Sign Out of All Websites" or the iPhone's). Chrome and Safari of the account quit in order (the
# "quit" Apple event, like shutdown.sh), then their site data goes: cookies, local and session storage, IndexedDB,
# service workers, saved tabs. Kept: Chrome's preferences (the search engine choice), bookmarks, the policies.
# Programs the person signed in to by hand (over screen sharing) are not touched.
# Prints "ok" or a reason; exit status 0 only when the data is gone.
set -u
source /usr/local/libexec/aos/settings.env   # GUEST_USER LOG
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
JXA='function run(a){ObjC.import("AppKit");return a.map(function(p){var x=$.NSRunningApplication.runningApplicationWithProcessIdentifier(parseInt(p,10));return p+":"+(x.isNil()?"gone":(x.terminate?"ok":"no"))}).join(" ")}'
note() { print -r -- "$(date '+%Y-%m-%d %H:%M:%S') signout: $*" >> "$LOG"; }
cd /
uid="$(id -u "$GUEST_USER" 2>/dev/null)" || { print "no account"; exit 3; }
home="$(dscl . -read "/Users/$GUEST_USER" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"
[ -d "$home" ] || { print "no home folder"; exit 3; }

browsers() { pgrep -u "$uid" -x "Google Chrome" 2>/dev/null; pgrep -u "$uid" -x "Safari" 2>/dev/null; }
quit_apps() {
  /bin/launchctl asuser "$uid" /usr/bin/sudo -u "$GUEST_USER" -- /usr/bin/osascript -l JavaScript -e "$JXA" "$@" \
    >>"$LOG" 2>&1 &
  local o=$!
  ( sleep 10; kill "$o" 2>/dev/null ) &
}

pids=($(browsers))
if (( ${#pids} )); then
  for i in {1..40}; do
    rest=($(browsers))
    (( ${#rest} )) || break
    (( (i - 1) % 6 == 0 )) && quit_apps "${rest[@]}"
    sleep 0.5
  done
  rest=($(browsers))
  if (( ${#rest} )); then
    kill -TERM "${rest[@]}" 2>/dev/null
    for i in {1..10}; do [ -z "$(browsers)" ] && break; sleep 0.5; done
    rest=($(browsers))
    (( ${#rest} )) && kill -KILL "${rest[@]}" 2>/dev/null
    sleep 1
  fi
  [ -z "$(browsers)" ] || { note "the browsers don't quit"; print "the browsers don't quit"; exit 4; }
fi

removed=0
chrome="$home/Library/Application Support/Google/Chrome"
if [ -d "$chrome" ]; then
  for p in "$chrome"/Default "$chrome"/Profile\ *(N); do
    [ -d "$p" ] || continue
    for item in Cookies Cookies-journal "Extension Cookies" "Extension Cookies-journal" "Local Storage" \
                "Session Storage" IndexedDB "Service Worker" Sessions "File System" Storage WebStorage \
                "Shared Storage" "Shared Storage-wal" "Trust Tokens" "Trust Tokens-journal" "Login Data" \
                "Login Data-journal" "Login Data For Account" "Login Data For Account-journal" databases; do
      [ -e "$p/$item" ] && { rm -rf -- "$p/$item"; removed=$((removed + 1)); }
    done
  done
  rm -f -- "$chrome/Safe Browsing Cookies" "$chrome/Safe Browsing Cookies-journal"
fi
for item in "$home/Library/Cookies" "$home/Library/Containers/com.apple.Safari/Data/Library/Cookies" \
            "$home/Library/Containers/com.apple.Safari/Data/Library/WebKit/WebsiteData" \
            "$home/Library/Safari/LocalStorage" "$home/Library/Safari/Databases"; do
  [ -e "$item" ] && { rm -rf -- "$item"; removed=$((removed + 1)); }
done
note "signed out of all websites ($removed items removed)"
print ok
