; The aOS installer for Windows (NSIS 3, built on the Mac with makensis by Tools/desktop.sh).
;
; Installs for the signed-in user into %LOCALAPPDATA%\Programs\aOS, without admin rights: the app (aOS.jar, the
; bundled Java in runtime\, the Go library in lib\), a Start menu shortcut, the aos-pair:// URL handler
; (HKCU\Software\Classes\aos-pair) and an entry under Apps to uninstall it. The app's start at login (HKCU Run, "aOS")
; is the app's own setting; uninstalling removes it. The app's data in %APPDATA%\aOS and its CNG keys stay unless the
; person agrees to delete them.
;
; makensis -DSRC=<folder "aOS"> -DICON=<.ico> -DOUTFILE=<Setup.exe> -DVERSION=0.1.0 -DARCH=x64|arm64 setup.nsi

Unicode true
ManifestDPIAware true
SetCompressor /SOLID lzma

!include "MUI2.nsh"

!define UNINST "Software\Microsoft\Windows\CurrentVersion\Uninstall\aOS"
!define RUN "Software\Microsoft\Windows\CurrentVersion\Run"
!define SCHEME "Software\Classes\aos-pair"

Name "aOS"
OutFile "${OUTFILE}"
InstallDir "$LOCALAPPDATA\Programs\aOS"
InstallDirRegKey HKCU "${UNINST}" "InstallLocation"
RequestExecutionLevel user
BrandingText "aOS ${VERSION} (${ARCH})"

VIProductVersion "${VERSION}.0"
VIAddVersionKey /LANG=0 "ProductName" "aOS"
VIAddVersionKey /LANG=0 "FileDescription" "aOS Setup"
VIAddVersionKey /LANG=0 "CompanyName" "marquart.dev"
VIAddVersionKey /LANG=0 "LegalCopyright" "marquart.dev"
VIAddVersionKey /LANG=0 "FileVersion" "${VERSION}"
VIAddVersionKey /LANG=0 "ProductVersion" "${VERSION}"

!define MUI_ICON "${ICON}"
!define MUI_UNICON "${ICON}"
!define MUI_ABORTWARNING
!define MUI_FINISHPAGE_RUN
!define MUI_FINISHPAGE_RUN_FUNCTION LaunchApp

!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH
!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES

!insertmacro MUI_LANGUAGE "German"
!insertmacro MUI_LANGUAGE "English"

LangString DeleteData ${LANG_GERMAN} "Auch die Daten von aOS löschen (gekoppelte Macs, Einstellungen)? Die Schlüssel in Windows bleiben."
LangString DeleteData ${LANG_ENGLISH} "Also delete aOS's data (paired Macs, settings)? The keys in Windows stay."

Function LaunchApp
  Exec '"$INSTDIR\runtime\bin\javaw.exe" -Daos.launcher=windows "-Daosgo.library=$INSTDIR\lib\aosgo.dll" -jar "$INSTDIR\aOS.jar"'
FunctionEnd

Section "aOS"
  SetOutPath "$INSTDIR"
  ; A running aOS holds its jar: end it first (javaw started from this folder).
  nsExec::Exec 'taskkill /F /FI "IMAGENAME eq javaw.exe" /FI "WINDOWTITLE eq aOS"'
  File /r "${SRC}\*.*"
  CreateShortcut "$SMPROGRAMS\aOS.lnk" "$INSTDIR\runtime\bin\javaw.exe" '-Daos.launcher=windows -Daosgo.library="$INSTDIR\lib\aosgo.dll" -jar "$INSTDIR\aOS.jar"' "$INSTDIR\aOS.ico"
  WriteRegStr HKCU "${SCHEME}" "" "URL:aOS pairing link"
  WriteRegStr HKCU "${SCHEME}" "URL Protocol" ""
  WriteRegStr HKCU "${SCHEME}\DefaultIcon" "" "$INSTDIR\aOS.ico"
  WriteRegStr HKCU "${SCHEME}\shell\open\command" "" '"$INSTDIR\runtime\bin\javaw.exe" "-Daos.launcher=windows" "-Daosgo.library=$INSTDIR\lib\aosgo.dll" "-jar" "$INSTDIR\aOS.jar" "%1"'
  WriteUninstaller "$INSTDIR\Uninstall.exe"
  WriteRegStr HKCU "${UNINST}" "DisplayName" "aOS"
  WriteRegStr HKCU "${UNINST}" "DisplayVersion" "${VERSION}"
  WriteRegStr HKCU "${UNINST}" "Publisher" "marquart.dev"
  WriteRegStr HKCU "${UNINST}" "DisplayIcon" "$INSTDIR\aOS.ico"
  WriteRegStr HKCU "${UNINST}" "InstallLocation" "$INSTDIR"
  WriteRegStr HKCU "${UNINST}" "UninstallString" '"$INSTDIR\Uninstall.exe"'
  WriteRegDWORD HKCU "${UNINST}" "NoModify" 1
  WriteRegDWORD HKCU "${UNINST}" "NoRepair" 1
SectionEnd

Section "Uninstall"
  nsExec::Exec 'taskkill /F /FI "IMAGENAME eq javaw.exe" /FI "WINDOWTITLE eq aOS"'
  Delete "$SMPROGRAMS\aOS.lnk"
  DeleteRegKey HKCU "${SCHEME}"
  DeleteRegValue HKCU "${RUN}" "aOS"
  DeleteRegKey HKCU "${UNINST}"
  RMDir /r "$INSTDIR"
  MessageBox MB_YESNO|MB_ICONQUESTION "$(DeleteData)" /SD IDNO IDNO keep
    RMDir /r "$APPDATA\aOS"
  keep:
SectionEnd
