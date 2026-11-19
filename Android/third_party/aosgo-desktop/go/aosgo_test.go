// aOS: tests of aosgo's C API glue (go-desktop.sh runs them on the build machine before building). The library itself
// is tested from the JVM through JNA (README.md, "Tests").
//
// Part of aOS's desktop wrapper of Open Screen Sharing (Android/third_party/aosgo-desktop in aOS); GPL-3.0.

package main

import (
	"bytes"
	"os"
	"regexp"
	"strconv"
	"strings"
	"testing"

	"github.com/nekohasekai/open-screen-sharing/libsharing"
)

func TestLowerCamel(t *testing.T) {
	for name, want := range map[string]string{
		"Width": "width", "HDR": "hdr", "PromptID": "promptID", "FrameID": "frameID", "DNSName": "dnsName",
		"SupportsHighPerformance": "supportsHighPerformance", "UDP": "udp", "MagicDNSSuffix": "magicDNSSuffix",
		"X": "x", "already": "already", "SupportsVNCPassword": "supportsVNCPassword",
	} {
		if got := lowerCamel(name); got != want {
			t.Errorf("lowerCamel(%q) = %q, want %q", name, got, want)
		}
	}
}

// The header's numbers are libsharing's: every AOSGO_ constant (but the event kinds) has its libsharing counterpart.
func TestHeaderConstantsAreLibsharings(t *testing.T) {
	want := map[string]int64{
		"PROTOCOL_RFB": int64(libsharing.ProtocolRFB), "PROTOCOL_RDP": int64(libsharing.ProtocolRDP),
		"PLATFORM_UNKNOWN": int64(libsharing.PlatformUnknown), "PLATFORM_MAC": int64(libsharing.PlatformMac),
		"PLATFORM_PC":   int64(libsharing.PlatformPC),
		"LOGIN_ACCOUNT": int64(libsharing.LoginAccount), "LOGIN_REQUEST_CONTROL": int64(libsharing.LoginRequestControl),
		"LOGIN_REQUEST_OBSERVE": int64(libsharing.LoginRequestObserve), "LOGIN_VNC_PASSWORD": int64(libsharing.LoginVNCPassword),
		"LOGIN_NONE":       int64(libsharing.LoginNone),
		"QUALITY_ADAPTIVE": int64(libsharing.QualityAdaptive), "QUALITY_FULL": int64(libsharing.QualityFull),
		"QUALITY_HIGH": int64(libsharing.QualityHigh), "QUALITY_MEDIUM": int64(libsharing.QualityMedium),
		"QUALITY_LOW":  int64(libsharing.QualityLow),
		"MODE_OBSERVE": int64(libsharing.ModeObserve), "MODE_CONTROL": int64(libsharing.ModeControl),
		"MODE_EXCLUSIVE_CONTROL": int64(libsharing.ModeExclusiveControl),
		"DIALECT_APPLE":          int64(libsharing.DialectApple), "DIALECT_STANDARD": int64(libsharing.DialectStandard),
		"DIALECT_RDP":   int64(libsharing.DialectRDP),
		"KEYBOARD_ANSI": int64(libsharing.KeyboardANSI), "KEYBOARD_ISO": int64(libsharing.KeyboardISO),
		"KEYBOARD_JIS":     int64(libsharing.KeyboardJIS),
		"STATE_CONNECTING": int64(libsharing.StateConnecting), "STATE_AUTHENTICATING": int64(libsharing.StateAuthenticating),
		"STATE_WAITING_FOR_APPROVAL": int64(libsharing.StateWaitingForApproval),
		"STATE_CHOOSING_SESSION":     int64(libsharing.StateChoosingSession), "STATE_CONNECTED": int64(libsharing.StateConnected),
		"STATE_DISCONNECTED": int64(libsharing.StateDisconnected),
		"ERROR_NONE":         int64(libsharing.ErrorNone), "ERROR_AUTHENTICATION": int64(libsharing.ErrorAuthentication),
		"ERROR_PERMISSION_DENIED": int64(libsharing.ErrorPermissionDenied), "ERROR_NETWORK": int64(libsharing.ErrorNetwork),
		"ERROR_PROTOCOL": int64(libsharing.ErrorProtocol), "ERROR_CANCELLED": int64(libsharing.ErrorCancelled),
		"ERROR_UNSUPPORTED_SERVER": int64(libsharing.ErrorUnsupportedServer),
		"ERROR_UNVERIFIED_SERVER":  int64(libsharing.ErrorUnverifiedServer),
		"ERROR_SESSION_ENDED":      int64(libsharing.ErrorSessionEnded), "ERROR_HOST_NOT_FOUND": int64(libsharing.ErrorHostNotFound),
		"ERROR_OWN_SCREEN": int64(libsharing.ErrorOwnScreen), "ERROR_CERTIFICATE_CHANGED": int64(libsharing.ErrorCertificateChanged),
		"BUTTON_LEFT": int64(libsharing.ButtonLeft), "BUTTON_MIDDLE": int64(libsharing.ButtonMiddle),
		"BUTTON_RIGHT":                   int64(libsharing.ButtonRight),
		"CLIPBOARD_PROBLEM_NOT_RESTORED": int64(libsharing.ClipboardProblemNotRestored),
		"SESSION_CHOICE_CANCEL":          int64(libsharing.SessionChoiceCancel),
		"SESSION_CHOICE_SHARE_CONSOLE":   int64(libsharing.SessionChoiceShareConsole),
		"SESSION_CHOICE_OWN_SESSION":     int64(libsharing.SessionChoiceOwnSession),
		"STATUS_CONTROL_ALLOWED":         int64(libsharing.StatusControlAllowed),
		"STATUS_OBSERVE_ONLY":            int64(libsharing.StatusObserveOnly),
		"STATUS_POINTER_HIDDEN":          int64(libsharing.StatusPointerHidden),
		"STATUS_POINTER_SHOWN":           int64(libsharing.StatusPointerShown),
		"ALL_DISPLAYS":                   libsharing.AllDisplays,
		"GESTURE_PHASE_BEGAN":            int64(libsharing.GesturePhaseBegan),
		"GESTURE_PHASE_CHANGED":          int64(libsharing.GesturePhaseChanged),
		"GESTURE_PHASE_ENDED":            int64(libsharing.GesturePhaseEnded),
		"GESTURE_PHASE_CANCELLED":        int64(libsharing.GesturePhaseCancelled),
		"GESTURE_PHASE_MAY_BEGIN":        int64(libsharing.GesturePhaseMayBegin),
		"SYSTEM_COMMAND_MISSION_CONTROL": int64(libsharing.SystemCommandMissionControl),
		"SYSTEM_COMMAND_APP_WINDOWS":     int64(libsharing.SystemCommandAppWindows),
		"SYSTEM_COMMAND_SHOW_DESKTOP":    int64(libsharing.SystemCommandShowDesktop),
		"SYSTEM_COMMAND_LAUNCHPAD":       int64(libsharing.SystemCommandLaunchpad),
		"CODEC_HEVC":                     int64(libsharing.CodecHEVC), "CODEC_H264": int64(libsharing.CodecH264),
		"DECODER_CODEC_HEVC": int64(libsharing.DecoderCodecHEVC),
		"DECODER_CODEC_H264": int64(libsharing.DecoderCodecH264),
		"MEDIA_ERROR_NONE":   int64(libsharing.MediaErrorNone), "MEDIA_ERROR_BUSY": int64(libsharing.MediaErrorBusy),
		"MEDIA_ERROR_REFUSED":       int64(libsharing.MediaErrorRefused),
		"MEDIA_ERROR_SILENT":        int64(libsharing.MediaErrorSilent),
		"MEDIA_ERROR_NETWORK":       int64(libsharing.MediaErrorNetwork),
		"VIDEO_MODE_CORE_DEVICE":    int64(libsharing.VideoModeCoreDevice),
		"VIDEO_MODE_REMOTE_DESKTOP": int64(libsharing.VideoModeRemoteDesktop),
		"FILE_ERROR_NONE":           int64(libsharing.FileErrorNone),
		"FILE_ERROR_CANCELLED":      int64(libsharing.FileErrorCancelled),
		"FILE_ERROR_NOT_ALLOWED":    int64(libsharing.FileErrorNotAllowed),
		"FILE_ERROR_NOT_FOUND":      int64(libsharing.FileErrorNotFound),
		"FILE_ERROR_NOT_WRITABLE":   int64(libsharing.FileErrorNotWritable),
		"FILE_ERROR_DISK_FULL":      int64(libsharing.FileErrorDiskFull),
		"FILE_ERROR_PERMISSION":     int64(libsharing.FileErrorPermission),
		"FILE_ERROR_LOCAL":          int64(libsharing.FileErrorLocal),
		"FILE_ERROR_CONNECTION":     int64(libsharing.FileErrorConnection),
		"FILE_ERROR_FAILED":         int64(libsharing.FileErrorFailed),
		"FILE_ERROR_OBSERVE_ONLY":   int64(libsharing.FileErrorObserveOnly),
		"FILE_ERROR_UNSUPPORTED":    int64(libsharing.FileErrorUnsupported),
	}
	header, err := os.ReadFile("aosgo.h")
	if err != nil {
		t.Fatal(err)
	}
	define := regexp.MustCompile(`(?m)^#define AOSGO_([A-Z0-9_]+) (.+)$`)
	seen := map[string]bool{}
	for _, m := range define.FindAllStringSubmatch(string(header), -1) {
		name, text := m[1], strings.Trim(m[2], "()")
		if strings.HasPrefix(name, "EVENT_") {
			continue
		}
		var value int64
		if shift, found := strings.CutPrefix(text, "1 << "); found {
			n, _ := strconv.Atoi(shift)
			value = 1 << n
		} else if value, err = strconv.ParseInt(text, 0, 64); err != nil {
			t.Errorf("AOSGO_%s: %q", name, text)
			continue
		}
		expected, known := want[name]
		if !known {
			t.Errorf("AOSGO_%s isn't checked against libsharing", name)
		} else if value != expected {
			t.Errorf("AOSGO_%s = %d, libsharing says %d", name, value, expected)
		}
		seen[name] = true
	}
	for name := range want {
		if !seen[name] {
			t.Errorf("aosgo.h lacks AOSGO_%s", name)
		}
	}
}

func TestClipboardLayoutRoundTrip(t *testing.T) {
	clipboard := libsharing.NewClipboard()
	item := libsharing.NewClipboardItem()
	item.AddFlavor("public.utf8-plain-text", []byte("hello"))
	item.AddFlavor("public.png", []byte{1, 2, 3})
	clipboard.AddItem(item)
	empty := libsharing.NewClipboardItem()
	empty.AddFlavor("public.url", nil)
	clipboard.AddItem(empty)

	text, data := clipboardJSON(clipboard)
	if !bytes.Equal(data, []byte("hello\x01\x02\x03")) {
		t.Fatalf("data %q", data)
	}
	back, err := clipboardFrom(text, data)
	if err != nil {
		t.Fatal(err)
	}
	if back.Len() != 2 || back.Get(0).Len() != 2 || string(back.Get(0).Get(0).Data) != "hello" ||
		back.Get(0).Get(1).Type != "public.png" || !bytes.Equal(back.Get(0).Get(1).Data, []byte{1, 2, 3}) ||
		back.Get(1).Get(0).Type != "public.url" {
		t.Fatalf("round trip: %s", text)
	}
	if _, err := clipboardFrom(`{"items":[{"flavors":[{"type":"x","offset":4,"length":9}]}]}`, data); err == nil {
		t.Fatal("a flavor outside the data was taken")
	}
}

func TestLengthPrefixed(t *testing.T) {
	got := lengthPrefixed([][]byte{{0x40, 0x01}, {}, {0x42}})
	want := []byte{0, 0, 0, 2, 0x40, 0x01, 0, 0, 0, 0, 0, 0, 0, 1, 0x42}
	if !bytes.Equal(got, want) {
		t.Fatalf("%x", got)
	}
}

func TestOptionsJSON(t *testing.T) {
	options, err := sessionOptions(`{"host":"mac.local","requireTrustedKey":true,"loginType":4,"decoderMaxPixelRate":1}`)
	if err != nil {
		t.Fatal(err)
	}
	if options.Host != "mac.local" || !options.RequireTrustedKey || options.LoginType != libsharing.LoginNone ||
		options.Port != 5900 || !options.SharedClipboard || options.DecoderMaxPixelRate != 1 {
		t.Fatalf("%+v", *options)
	}
	if _, err := sessionOptions(`{"hots":"typo"}`); err == nil {
		t.Fatal("an unknown key was taken")
	}
	hp, err := highPerformanceOptions(`{"bands":4,"videoMode":5}`)
	if err != nil || hp.Bands != 4 || hp.VideoMode != 5 || hp.SupportedCodecs != libsharing.DecoderCodecHEVC || !hp.Audio {
		t.Fatalf("%+v %v", hp, err)
	}
	info := object(&libsharing.ServerInfo{Width: 3, SupportsHighPerformance: true})
	if info["width"] != int32(3) || info["supportsHighPerformance"] != true {
		t.Fatalf("%v", info)
	}
	unit := object(&libsharing.VideoAccessUnit{Data: []byte{1}, FrameID: 7})
	if _, found := unit["data"]; found || unit["frameID"] != int64(7) {
		t.Fatalf("%v", unit)
	}
}
