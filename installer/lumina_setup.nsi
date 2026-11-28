; NSIS Modern UI 2 Installer Script for Lumina Audio v0.2.6
Unicode True
SetCompressor /SOLID lzma

!define APP_NAME "Lumina Audio"
!define APP_VERSION "0.2.6"
!define APP_PUBLISHER "Lumina Audio Team"
!define APP_URL "https://github.com/pierre930523/lumina-audio"
!define APP_EXE "lumina_app.exe"
!define UNINSTALL_REG_KEY "Software\Microsoft\Windows\CurrentVersion\Uninstall\LuminaAudio"

Name "${APP_NAME} v${APP_VERSION}"
OutFile "..\dist\Lumina-Audio-Setup-v${APP_VERSION}.exe"
InstallDir "$LOCALAPPDATA\Programs\Lumina Audio"
InstallDirRegKey HKCU "Software\LuminaAudio" "Install_Dir"
RequestExecutionLevel user
BrandingText "${APP_NAME} v${APP_VERSION} — Audiophile Lossless Music Player"

!include "MUI2.nsh"

!define MUI_ABORTWARNING
!define MUI_ICON "..\app\windows\runner\resources\app_icon.ico"
!define MUI_UNICON "..\app\windows\runner\resources\app_icon.ico"
!define MUI_FINISHPAGE_RUN "$INSTDIR\${APP_EXE}"
!define MUI_FINISHPAGE_RUN_TEXT "立即啟動 ${APP_NAME}"

!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH

!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES

!insertmacro MUI_LANGUAGE "TradChinese"
!insertmacro MUI_LANGUAGE "English"

VIProductVersion "0.2.6.0"
VIAddVersionKey /LANG=${LANG_TRADCHINESE} "ProductName" "${APP_NAME}"
VIAddVersionKey /LANG=${LANG_TRADCHINESE} "CompanyName" "${APP_PUBLISHER}"
VIAddVersionKey /LANG=${LANG_TRADCHINESE} "FileDescription" "${APP_NAME} Setup (NSIS)"
VIAddVersionKey /LANG=${LANG_TRADCHINESE} "FileVersion" "${APP_VERSION}.0"
VIAddVersionKey /LANG=${LANG_TRADCHINESE} "ProductVersion" "${APP_VERSION}.0"
VIAddVersionKey /LANG=${LANG_TRADCHINESE} "LegalCopyright" "MIT License - ${APP_PUBLISHER}"

Section "Lumina Audio 主程式 (必選)" SecCore
  SectionIn RO
  SetOutPath "$INSTDIR"

  ; Package full Flutter Windows Release bundle (exe, core_ffi.dll, WebView2Loader.dll, MSVC CRT DLLs, data/, bin/, THIRD_PARTY_LICENSES.txt, etc.)
  File /r "..\app\build\windows\x64\runner\Release\*.*"

  ; Persist install directory
  WriteRegStr HKCU "Software\LuminaAudio" "Install_Dir" "$INSTDIR"

  ; Write Windows Add/Remove Programs uninstaller metadata
  WriteRegStr HKCU "${UNINSTALL_REG_KEY}" "DisplayName" "${APP_NAME}"
  WriteRegStr HKCU "${UNINSTALL_REG_KEY}" "DisplayVersion" "${APP_VERSION}"
  WriteRegStr HKCU "${UNINSTALL_REG_KEY}" "Publisher" "${APP_PUBLISHER}"
  WriteRegStr HKCU "${UNINSTALL_REG_KEY}" "URLInfoAbout" "${APP_URL}"
  WriteRegStr HKCU "${UNINSTALL_REG_KEY}" "DisplayIcon" "$\"$INSTDIR\${APP_EXE}$\",0"
  WriteRegStr HKCU "${UNINSTALL_REG_KEY}" "UninstallString" "$\"$INSTDIR\Uninstall.exe$\""
  WriteRegStr HKCU "${UNINSTALL_REG_KEY}" "QuietUninstallString" "$\"$INSTDIR\Uninstall.exe$\" /S"
  WriteRegDWORD HKCU "${UNINSTALL_REG_KEY}" "NoModify" 1
  WriteRegDWORD HKCU "${UNINSTALL_REG_KEY}" "NoRepair" 1

  WriteUninstaller "$INSTDIR\Uninstall.exe"

  ; Start Menu & Desktop Shortcuts
  CreateDirectory "$SMPROGRAMS\${APP_NAME}"
  CreateShortcut "$SMPROGRAMS\${APP_NAME}\${APP_NAME}.lnk" "$INSTDIR\${APP_EXE}" "" "$INSTDIR\${APP_EXE}" 0
  CreateShortcut "$SMPROGRAMS\${APP_NAME}\Uninstall ${APP_NAME}.lnk" "$INSTDIR\Uninstall.exe" "" "$INSTDIR\Uninstall.exe" 0
  CreateShortcut "$DESKTOP\${APP_NAME}.lnk" "$INSTDIR\${APP_EXE}" "" "$INSTDIR\${APP_EXE}" 0
SectionEnd

Section "Uninstall"
  Delete "$DESKTOP\${APP_NAME}.lnk"
  Delete "$SMPROGRAMS\${APP_NAME}\${APP_NAME}.lnk"
  Delete "$SMPROGRAMS\${APP_NAME}\Uninstall ${APP_NAME}.lnk"
  RMDir "$SMPROGRAMS\${APP_NAME}"

  RMDir /r "$INSTDIR\bin"
  RMDir /r "$INSTDIR\data"
  Delete "$INSTDIR\THIRD_PARTY_LICENSES.txt"
  Delete "$INSTDIR\*.dll"
  Delete "$INSTDIR\*.exe"
  Delete "$INSTDIR\*.dat"
  Delete "$INSTDIR\*.exp"
  Delete "$INSTDIR\*.lib"
  Delete "$INSTDIR\*.pdb"
  RMDir /r "$INSTDIR"

  DeleteRegKey HKCU "${UNINSTALL_REG_KEY}"
  DeleteRegKey HKCU "Software\LuminaAudio"
SectionEnd
