#!/bin/zsh
# Builds the aOS desktop packages (Windows and Linux) on this Mac, each with its own Java runtime (Eclipse Temurin 21
# JRE, pinned below with its SHA-256) and the desktop Go library for that system (Android/third_party/aosgo-desktop,
# Android/Tools/go-desktop.sh; without it the package has no screen sessions and no aOS Tailscale, and says so).
#
#   Tools/desktop.sh                     all targets
#   Tools/desktop.sh windows-x64 ...     some of: windows-x64 windows-arm64 linux-x64 linux-arm64
#
# Results in build/:
#   aOS-windows-<arch>.zip      folder "aOS": aOS.jar, runtime\, lib\aosgo.dll, aOS.bat, LIESMICH.txt (unzip, start)
#   aOS-Setup-<arch>.exe        the same as an installer (NSIS, if makensis is there): per user, no admin rights,
#                               Start menu, aos-pair:// in HKCU\Software\Classes, uninstall under Apps
#   aOS-linux-<arch>.tar.gz     folder "aos": aos (start script), aOS.jar, runtime/, lib/libaosgo.so, aos.png
#   aos_<version>_<arch>.deb    /opt/aos, /usr/bin/aos, aos.desktop with x-scheme-handler/aos-pair, the polkit action
#                               and the PAM service for "confirm with the password" (if dpkg-deb is there)
#
# jpackage only builds for the system it runs on, hence zip/tar with a downloaded runtime per target. Nothing is
# signed: Windows SmartScreen warns on the first start ("More info", "Run anyway").
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD
VERSION=$(awk -F'"' '/^val appVersion/ {print $2}' Android/desktop/build.gradle.kts)
TARGETS=("$@")
[ ${#TARGETS[@]} -eq 0 ] && TARGETS=(windows-x64 windows-arm64 linux-x64 linux-arm64)

# Temurin 21 JREs (adoptium.net), fixed versions and checksums (checked 2026-11-19).
jre_url() {
  case "$1" in
    windows-x64) echo "https://github.com/adoptium/temurin21-binaries/releases/download/jdk-21.0.13%2B9/OpenJDK21U-jre_x64_windows_hotspot_21.0.13_9.zip 2332c0b4cff6bed722da3567c91d5e47568bcba863fa4945d0a8d6fc76158628" ;;
    windows-arm64) echo "https://github.com/adoptium/temurin21-binaries/releases/download/jdk-21.0.12.1%2B1/OpenJDK21U-jre_aarch64_windows_hotspot_21.0.12.1_1.zip e82cc17e0bf89a25b0b0ed106d072f2ea420587d0a6870534b71b1dce3ae28c3" ;;
    linux-x64) echo "https://github.com/adoptium/temurin21-binaries/releases/download/jdk-21.0.13.1%2B2/OpenJDK21U-jre_x64_linux_hotspot_21.0.13.1_2.tar.gz 18f44fab9065217f3ba61d0eef8a7b5f3c3713aa7293001b0d4ac10ede3850f0" ;;
    linux-arm64) echo "https://github.com/adoptium/temurin21-binaries/releases/download/jdk-21.0.13%2B9/OpenJDK21U-jre_aarch64_linux_hotspot_21.0.13_9.tar.gz b1734db7ade49c3f6acc6ae06233b8c2dd90e3e2f00f67000ae1c972aaa64d8c" ;;
    *) echo "unknown target $1" >&2; exit 1 ;;
  esac
}
go_target() {
  case "$1" in windows-x64) echo windows-amd64 ;; windows-arm64) echo windows-arm64 ;; linux-x64) echo linux-amd64 ;; linux-arm64) echo linux-arm64 ;; esac
}

JOBS=()
for t in "${TARGETS[@]}"; do JOBS+=(":desktop:jar-$t"); done
Tools/android.sh -q "${JOBS[@]}"

CACHE=build/desktop-jre
OUT=build/desktop
mkdir -p "$CACHE" "$OUT"
ICON_PNG=Android/shared-ui/src/main/res/drawable-nodpi/aos_icon_art.png

for t in "${TARGETS[@]}"; do
  read URL SUM <<< "$(jre_url "$t")"
  FILE="$CACHE/${URL##*/}"
  if [ ! -f "$FILE" ]; then
    echo "Downloading the Java runtime for $t (${URL##*/}) ..."
    curl -fsSL -o "$FILE.part" "$URL"
    mv "$FILE.part" "$FILE"
  fi
  HAVE=$(shasum -a 256 "$FILE" | awk '{print $1}')
  [ "$HAVE" = "$SUM" ] || { echo "Checksum of $FILE doesn't match ($HAVE)."; rm -f "$FILE"; exit 1; }

  GO="Android/third_party/aosgo-desktop/out/$(go_target "$t")"
  rm -rf "${OUT:?}/${t:?}"
  TMP=$(mktemp -d)
  case "$t" in
    windows-*)
      DIR="$OUT/$t/aOS"; mkdir -p "$DIR/lib" "$DIR/licenses"
      cp "Android/desktop/build/package/$t/aOS.jar" "$DIR/"
      unzip -q "$FILE" -d "${TMP:?}"; mv "$TMP"/*/ "$DIR/runtime"
      if [ -f "$GO/aosgo.dll" ]; then cp "$GO/aosgo.dll" "$GO/aosgo.source" "$DIR/lib/"; else echo "Note: no Go library for $t (Tools/go-desktop.sh)."; fi
      printf '@echo off\r\nstart "" "%%~dp0runtime\\bin\\javaw.exe" -Daos.launcher=windows "-Daosgo.library=%%~dp0lib\\aosgo.dll" -jar "%%~dp0aOS.jar" %%*\r\n' > "$DIR/aOS.bat"
      ;;
    linux-*)
      DIR="$OUT/$t/aos"; mkdir -p "$DIR/lib" "$DIR/licenses"
      cp "Android/desktop/build/package/$t/aOS.jar" "$DIR/"
      tar -xzf "$FILE" -C "${TMP:?}"; mv "$TMP"/*/ "$DIR/runtime"
      if [ -f "$GO/libaosgo.so" ]; then cp "$GO/libaosgo.so" "$GO/aosgo.source" "$DIR/lib/"; else echo "Note: no Go library for $t (Tools/go-desktop.sh)."; fi
      cp Android/desktop/packaging/linux/aos "$DIR/aos"; chmod 755 "$DIR/aos"
      cp "$ICON_PNG" "$DIR/aos.png"
      ;;
  esac
  rmdir "${TMP:?}"
  # Licenses: the app's (GPL-3.0, because it ships libsharing), Open Screen Sharing's notice, Tailscale's, Apache-2.0.
  for f in license_gpl3 license_open_screen_sharing license_tailscale license_apache2; do
    cp "Android/shared-ui/src/main/res/raw/$f.txt" "$DIR/licenses/${f#license_}.txt"
  done
done

# Windows: README, zip, icon, installer
for t in "${TARGETS[@]}"; do
  [[ "$t" == windows-* ]] || continue
  DIR="$OUT/$t/aOS"
  cat > "$DIR/LIESMICH.txt" <<'TXT'
aOS für Windows

1. Den Ordner "aOS" an einen festen Ort legen, zum Beispiel unter Dokumente.
2. "aOS.bat" doppelklicken. Windows kann beim ersten Mal warnen, weil die Datei nicht signiert ist:
   "Weitere Informationen", dann "Trotzdem ausführen".
3. In aOS: "Mit einem Mac koppeln", den Kopplungslink aus aOS auf dem Mac einfügen.
4. aOS bleibt im Infobereich unten rechts, wenn das Fenster zu ist. Start bei der Anmeldung:
   Einstellungen, Im Hintergrund.

Daten: %APPDATA%\aOS. Schlüssel: in Windows (TPM, sonst Windows-Schlüsselspeicher), nicht exportierbar.
Lizenzen: Ordner licenses (aOS enthält Open Screen Sharing unter der GPL-3.0).
TXT
  sed -i '' 's/$/\r/' "$DIR/LIESMICH.txt"
  python3 - "$ICON_PNG" "$DIR/aOS.ico" <<'PY'
import os, struct, subprocess, sys, tempfile
src, out = sys.argv[1:3]
sizes = [16, 24, 32, 48, 64, 128, 256]
images = []
with tempfile.TemporaryDirectory() as tmp:
    for n in sizes:
        png = os.path.join(tmp, f"{n}.png")
        subprocess.run(["sips", "-z", str(n), str(n), src, "--out", png], check=True, capture_output=True)
        images.append(open(png, "rb").read())
head = struct.pack("<HHH", 0, 1, len(sizes))
offset = 6 + 16 * len(sizes)
entries = b""
for n, data in zip(sizes, images):
    entries += struct.pack("<BBBBHHII", n % 256, n % 256, 0, 0, 1, 32, len(data), offset)
    offset += len(data)
open(out, "wb").write(head + entries + b"".join(images))
PY
  rm -f "build/aOS-$t.zip"
  (cd "$OUT/$t" && zip -qr -9 "$ROOT/build/aOS-$t.zip" aOS)
  ls -la "build/aOS-$t.zip"
  if command -v makensis > /dev/null; then
    ARCH=${t#windows-}
    LC_ALL=en_US.UTF-8 makensis -V2 -DSRC="$ROOT/$DIR" -DICON="$ROOT/$DIR/aOS.ico" -DOUTFILE="$ROOT/build/aOS-Setup-$ARCH.exe" \
      -DVERSION="$VERSION" -DARCH="$ARCH" Android/desktop/packaging/windows/setup.nsi
    ls -la "build/aOS-Setup-$ARCH.exe"
  else
    echo "No makensis: installer skipped (brew install makensis)."
  fi
done

# Linux: tar.gz and .deb
for t in "${TARGETS[@]}"; do
  [[ "$t" == linux-* ]] || continue
  DIR="$OUT/$t/aos"
  cat > "$DIR/README.txt" <<'TXT'
aOS for Linux (x86_64 or aarch64, glibc 2.28 or newer)

Start: ./aos   (the first start registers aos-pair:// links for your user: ~/.local/share/applications/aos.desktop)
Keys and settings: ~/.config/aos (0600). With a keyring (GNOME Keyring, KWallet: libsecret) the key file is
encrypted with a key kept there; without one it is a plain 0600 file (Settings says so).
Confirming approvals: Settings, "Confirm approvals with": the system's dialog (polkit, pkcheck), the password of
your account (PAM, service "login"; the .deb installs its own "aos" service), or not at all.
The .deb installs to /opt/aos with /usr/bin/aos, the menu entry, the URL handler, the polkit action and PAM service.
Licenses: licenses/ (aOS ships Open Screen Sharing under GPL-3.0).
TXT
  rm -f "build/aOS-$t.tar.gz"
  COPYFILE_DISABLE=1 tar --uid 0 --gid 0 -czf "build/aOS-$t.tar.gz" -C "$OUT/$t" aos
  ls -la "build/aOS-$t.tar.gz"
  if command -v dpkg-deb > /dev/null; then
    DEBARCH=$([ "$t" = linux-x64 ] && echo amd64 || echo arm64)
    STAGE="$OUT/$t/deb"
    mkdir -p "$STAGE/DEBIAN" "$STAGE/opt" "$STAGE/usr/bin" "$STAGE/usr/share/applications" \
      "$STAGE/usr/share/icons/hicolor/256x256/apps" "$STAGE/usr/share/polkit-1/actions" "$STAGE/etc/pam.d"
    cp -R "$DIR" "$STAGE/opt/aos"
    ln -s /opt/aos/aos "$STAGE/usr/bin/aos"
    sips -z 256 256 "$ICON_PNG" --out "$STAGE/usr/share/icons/hicolor/256x256/apps/aos.png" > /dev/null
    cp Android/desktop/packaging/linux/dev.marquart.aos.confirm.policy "$STAGE/usr/share/polkit-1/actions/"
    cp Android/desktop/packaging/linux/pam-aos "$STAGE/etc/pam.d/aos"
    cat > "$STAGE/usr/share/applications/aos.desktop" <<'DESKTOP'
[Desktop Entry]
Type=Application
Name=aOS
Comment=Approve sign-ins, open the terminal and the screen of your Mac
Comment[de]=Anmeldungen freigeben, Terminal und Bildschirm deines Macs öffnen
Exec=/opt/aos/aos %u
Icon=aos
Categories=Network;RemoteAccess;
MimeType=x-scheme-handler/aos-pair;
StartupWMClass=aOS
DESKTOP
    SIZE=$(du -sk "$STAGE/opt" | awk '{print $1}')
    cat > "$STAGE/DEBIAN/control" <<CONTROL
Package: aos
Version: $VERSION
Architecture: $DEBARCH
Maintainer: marquart.dev <max@marquart.dev>
Installed-Size: $SIZE
Depends: libc6 (>= 2.28)
Recommends: libsecret-1-0, policykit-1 | polkitd, libnotify-bin
Section: net
Priority: optional
Homepage: https://marquart.dev/aos
Description: aOS companion for your Mac
 Approve sign-ins and requests from your agent, open the Mac's terminal and the
 screen of its workspace. Pairs with aOS on the Mac over SSH.
CONTROL
    cat > "$STAGE/DEBIAN/postinst" <<'POST'
#!/bin/sh
set -e
command -v update-desktop-database >/dev/null && update-desktop-database -q /usr/share/applications || true
command -v gtk-update-icon-cache >/dev/null && gtk-update-icon-cache -q /usr/share/icons/hicolor || true
exit 0
POST
    chmod 755 "$STAGE/DEBIAN/postinst"
    cp "$STAGE/DEBIAN/postinst" "$STAGE/DEBIAN/postrm"
    chmod -R go-w "$STAGE"
    rm -f "build/aos_${VERSION}_$DEBARCH.deb"
    dpkg-deb --root-owner-group -Zxz --build "$STAGE" "build/aos_${VERSION}_$DEBARCH.deb" > /dev/null
    rm -rf "${STAGE:?}"
    ls -la "build/aos_${VERSION}_$DEBARCH.deb"
  else
    echo "No dpkg-deb: .deb skipped (brew install dpkg)."
  fi
done
