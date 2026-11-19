// aOS: libsharing's session in aosgo's C API (aosgo.h, "libsharing"): sessions as handles, SessionHandler as one C
// callback per session, structured values as JSON and bytes.
//
// Part of aOS's desktop wrapper of Open Screen Sharing (Android/third_party/aosgo-desktop in aOS). Based on Open
// Screen Sharing by nekohasekai, GPL-3.0; this file is GPL-3.0 too (iOS/ThirdParty/OpenScreenSharing/LICENSE and
// COPYING in aOS).

package main

/*
#include <stdlib.h>
#include "aosgo.h"

static inline void aosgo_call_session(aosgo_session_fn fn, int64_t session, int32_t kind, int64_t a, int64_t b,
                                      int64_t c, int64_t d, int64_t e, const char *text, const void *data,
                                      int64_t length) {
	fn(session, kind, a, b, c, d, e, text, data, length);
}
*/
import "C"

import (
	"encoding/binary"
	"errors"
	"fmt"
	"sync"
	"sync/atomic"
	"unsafe"

	"github.com/nekohasekai/open-screen-sharing/libsharing"
)

const utf8PlainText = "public.utf8-plain-text"

var sessions registry[*session]

// session is one libsharing session behind a handle, and its SessionHandler.
type session struct {
	id       int64
	session  *libsharing.Session
	callback C.aosgo_session_fn

	mu        sync.Mutex
	running   bool // connected, DISCONNECTED not yet delivered
	freed     bool // aosgo_session_free was called
	gone      atomic.Bool
	transfers map[int64]*libsharing.FileTransfer
}

func lookup(handle C.int64_t) (*session, error) {
	s, found := sessions.get(int64(handle))
	if !found {
		return nil, fmt.Errorf("aosgo: no session %d", int64(handle))
	}
	return s, nil
}

// call runs fn on the session's libsharing session, for the exported functions that return a status.
func call(handle C.int64_t, out **C.char, fn func(*libsharing.Session) error) (result C.int32_t) {
	defer guard(out)
	result = -1
	s, err := lookup(handle)
	if err != nil {
		return status(out, err)
	}
	return status(out, fn(s.session))
}

// emit hands an event to the C callback. text nil is NULL.
func (s *session) emit(kind C.int32_t, a, b, c, d, e int64, text *string, data []byte) {
	if s.gone.Load() {
		return
	}
	var textBytes []byte
	if text != nil {
		textBytes = cText(*text)
	}
	C.aosgo_call_session(s.callback, C.int64_t(s.id), kind, C.int64_t(a), C.int64_t(b), C.int64_t(c), C.int64_t(d),
		C.int64_t(e), textPointer(textBytes), dataPointer(data), C.int64_t(len(data)))
}

func ptr(s string) *string { return &s }

// MARK: SessionHandler

func (s *session) OnStateChanged(state int32, errorCode int32, message string) {
	s.emit(C.AOSGO_EVENT_STATE, int64(state), int64(errorCode), 0, 0, 0, ptr(message), nil)
	if state != libsharing.StateDisconnected {
		return
	}
	s.mu.Lock()
	s.running = false
	freed := s.freed
	s.mu.Unlock()
	if freed {
		s.release()
	}
}

func (s *session) OnServerInfo(info *libsharing.ServerInfo) {
	if info == nil {
		return
	}
	s.emit(C.AOSGO_EVENT_SERVER_INFO, 0, 0, 0, 0, 0, ptr(jsonText(object(info))), nil)
}

func (s *session) OnServerCertificate(fingerprint string) {
	s.emit(C.AOSGO_EVENT_SERVER_CERTIFICATE, 0, 0, 0, 0, 0, ptr(fingerprint), nil)
}

func (s *session) OnFramebufferResize(width int32, height int32) {
	s.emit(C.AOSGO_EVENT_FRAMEBUFFER_RESIZE, int64(width), int64(height), 0, 0, 0, nil, nil)
}

func (s *session) OnFramebufferUpdate(update *libsharing.FramebufferUpdate) {
	if update == nil {
		return
	}
	s.emit(C.AOSGO_EVENT_FRAMEBUFFER_UPDATE, int64(update.X), int64(update.Y), int64(update.Width),
		int64(update.Height), update.HoldNanoseconds, nil, nil)
}

func (s *session) OnCursorImage(cursor *libsharing.CursorImage) {
	if cursor == nil {
		s.emit(C.AOSGO_EVENT_CURSOR_IMAGE, 0, 0, 0, 0, 0, nil, nil)
		return
	}
	data := make([]byte, 0, len(cursor.Pixels)+len(cursor.Invert))
	data = append(append(data, cursor.Pixels...), cursor.Invert...)
	if len(cursor.Pixels) < int(cursor.Width)*int(cursor.Height)*4 {
		// Not a whole picture: report no cursor image rather than a short one.
		s.emit(C.AOSGO_EVENT_CURSOR_IMAGE, 0, 0, 0, 0, 0, nil, nil)
		return
	}
	s.emit(C.AOSGO_EVENT_CURSOR_IMAGE, int64(cursor.Width), int64(cursor.Height), int64(cursor.HotspotX),
		int64(cursor.HotspotY), int64(len(cursor.Invert)), nil, data)
}

func (s *session) OnCursorPosition(x int32, y int32) {
	s.emit(C.AOSGO_EVENT_CURSOR_POSITION, int64(x), int64(y), 0, 0, 0, nil, nil)
}

func (s *session) OnDisplays(displays *libsharing.DisplayList) {
	if displays == nil {
		return
	}
	list := make([]map[string]any, 0, displays.Len())
	for i := int32(0); i < displays.Len(); i++ {
		list = append(list, object(displays.Get(i)))
	}
	value := object(displays)
	value["displays"] = list
	s.emit(C.AOSGO_EVENT_DISPLAYS, 0, 0, 0, 0, 0, ptr(jsonText(value)), nil)
}

// clipboardJSON lays a clipboard out as the CLIPBOARD event does: JSON with offsets into one byte array.
func clipboardJSON(clipboard *libsharing.Clipboard) (string, []byte) {
	type flavor struct {
		Type    string `json:"type"`
		Promise bool   `json:"promise"`
		Offset  int    `json:"offset"`
		Length  int    `json:"length"`
	}
	type item struct {
		Flavors []flavor `json:"flavors"`
	}
	var layout struct {
		Items []item `json:"items"`
	}
	layout.Items = []item{}
	var data []byte
	for i := int32(0); i < clipboard.Len(); i++ {
		source := clipboard.Get(i)
		it := item{Flavors: []flavor{}}
		for j := int32(0); j < source.Len(); j++ {
			f := source.Get(j)
			it.Flavors = append(it.Flavors, flavor{Type: f.Type, Promise: f.Promise, Offset: len(data), Length: len(f.Data)})
			data = append(data, f.Data...)
		}
		layout.Items = append(layout.Items, it)
	}
	return jsonText(layout), data
}

// clipboardFrom reads the CLIPBOARD layout back (for set and paste).
func clipboardFrom(text string, data []byte) (*libsharing.Clipboard, error) {
	var layout struct {
		Items []struct {
			Flavors []struct {
				Type    string `json:"type"`
				Promise bool   `json:"promise"`
				Offset  int64  `json:"offset"`
				Length  int64  `json:"length"`
			} `json:"flavors"`
		} `json:"items"`
	}
	if err := decodeInto(text, &layout); err != nil {
		return nil, err
	}
	clipboard := libsharing.NewClipboard()
	for _, it := range layout.Items {
		item := libsharing.NewClipboardItem()
		for _, f := range it.Flavors {
			if f.Offset < 0 || f.Length < 0 || f.Offset+f.Length > int64(len(data)) {
				return nil, fmt.Errorf("aosgo: clipboard flavor %q lies outside the %d bytes of data", f.Type, len(data))
			}
			item.AddFlavor(f.Type, data[f.Offset:f.Offset+f.Length]) // copies
		}
		clipboard.AddItem(item)
	}
	return clipboard, nil
}

func (s *session) OnClipboard(clipboard *libsharing.Clipboard) {
	if clipboard == nil {
		return
	}
	text, data := clipboardJSON(clipboard)
	s.emit(C.AOSGO_EVENT_CLIPBOARD, 0, 0, 0, 0, 0, &text, data)
}

func (s *session) OnClipboardProblem(kind int32, message string) {
	s.emit(C.AOSGO_EVENT_CLIPBOARD_PROBLEM, int64(kind), 0, 0, 0, 0, ptr(message), nil)
}

func (s *session) OnBell() {
	s.emit(C.AOSGO_EVENT_BELL, 0, 0, 0, 0, 0, nil, nil)
}

func (s *session) OnKeyboardSource(sourceID string, secureInput bool) {
	s.emit(C.AOSGO_EVENT_KEYBOARD_SOURCE, int64(cBool(secureInput)), 0, 0, 0, 0, ptr(sourceID), nil)
}

func (s *session) OnStatus(status int32) {
	s.emit(C.AOSGO_EVENT_STATUS, int64(status), 0, 0, 0, 0, nil, nil)
}

func (s *session) OnPrompt(prompt *libsharing.Prompt) {
	if prompt == nil {
		return
	}
	s.emit(C.AOSGO_EVENT_PROMPT, prompt.PromptID, int64(cBool(prompt.AllowsShareConsole)),
		int64(cBool(prompt.AllowsOwnSession)), 0, 0, ptr(prompt.ConsoleUser), nil)
}

// lengthPrefixed puts units one after the other, each after its 4 byte big-endian length.
func lengthPrefixed(units [][]byte) []byte {
	size := 0
	for _, unit := range units {
		size += 4 + len(unit)
	}
	data := make([]byte, 0, size)
	for _, unit := range units {
		data = binary.BigEndian.AppendUint32(data, uint32(len(unit)))
		data = append(data, unit...)
	}
	return data
}

func (s *session) OnVideoFormat(format *libsharing.VideoFormat) {
	if format == nil {
		return
	}
	sets := make([][]byte, 0, format.Len())
	for i := int32(0); i < format.Len(); i++ {
		sets = append(sets, format.Get(i))
	}
	s.emit(C.AOSGO_EVENT_VIDEO_FORMAT, int64(format.Codec), int64(format.Bands), int64(format.Height),
		int64(format.ChromaFormat), int64(cBool(format.HDR)), nil, lengthPrefixed(sets))
}

func (s *session) OnVideoAccessUnit(unit *libsharing.VideoAccessUnit) {
	if unit == nil {
		return
	}
	s.emit(C.AOSGO_EVENT_VIDEO_ACCESS_UNIT, unit.Timestamp, int64(unit.ClockRate), int64(cBool(unit.Sync)),
		int64(cBool(unit.Discontinuity)), int64(cBool(unit.FrameEnd)), ptr(jsonText(object(unit))), unit.Data)
}

func (s *session) audioFormat(kind C.int32_t, format *libsharing.AudioFormat) {
	if format == nil {
		return
	}
	s.emit(kind, format.FormatID, int64(format.SampleRate), int64(format.Channels), int64(format.FramesPerPacket), 0,
		nil, format.MagicCookie)
}

func (s *session) OnAudioFormat(format *libsharing.AudioFormat) {
	s.audioFormat(C.AOSGO_EVENT_AUDIO_FORMAT, format)
}

func (s *session) OnAudioPacket(packet *libsharing.AudioPacket) {
	if packet == nil {
		return
	}
	s.emit(C.AOSGO_EVENT_AUDIO_PACKET, packet.Timestamp, int64(packet.Lost), 0, 0, 0, nil, packet.Data)
}

func (s *session) OnMicrophone(format *libsharing.AudioFormat) {
	s.audioFormat(C.AOSGO_EVENT_MICROPHONE, format)
}

func (s *session) OnMediaStopped(errorCode int32, message string) {
	s.emit(C.AOSGO_EVENT_MEDIA_STOPPED, int64(errorCode), 0, 0, 0, 0, ptr(message), nil)
}

func (s *session) OnFileTransferProgress(transferID int64, transferred int64, total int64) {
	s.emit(C.AOSGO_EVENT_FILE_TRANSFER_PROGRESS, transferID, transferred, total, 0, 0, nil, nil)
}

func (s *session) OnFileTransferFinished(transferID int64, name string, errorCode int32, message string) {
	s.mu.Lock()
	delete(s.transfers, transferID)
	s.mu.Unlock()
	s.emit(C.AOSGO_EVENT_FILE_TRANSFER_FINISHED, transferID, int64(errorCode), 0, 0, 0,
		ptr(jsonText(map[string]string{"name": name, "message": message})), nil)
}

func (s *session) OnDropDestination(dragID int64, path string) {
	s.emit(C.AOSGO_EVENT_DROP_DESTINATION, dragID, 0, 0, 0, 0, ptr(path), nil)
}

func (s *session) OnRemoteDrag(drag *libsharing.RemoteDrag) {
	if drag == nil {
		s.emit(C.AOSGO_EVENT_REMOTE_DRAG, 0, 0, 0, 0, 0, nil, nil)
		return
	}
	items := make([]map[string]any, 0, drag.Len())
	for i := int32(0); i < drag.Len(); i++ {
		items = append(items, map[string]any{"path": drag.Path(i), "isFolder": drag.IsFolder(i)})
	}
	s.emit(C.AOSGO_EVENT_REMOTE_DRAG, 0, 0, 0, 0, 0, ptr(jsonText(map[string]any{"items": items})), drag.Image)
}

func (s *session) OnDeviceInfo(model string, deviceColor string, enclosureColor string) {
	s.emit(C.AOSGO_EVENT_DEVICE_INFO, 0, 0, 0, 0, 0, ptr(jsonText(map[string]string{"model": model,
		"deviceColor": deviceColor, "enclosureColor": enclosureColor})), nil)
}

// release drops the handle; no events after it.
func (s *session) release() {
	s.gone.Store(true)
	sessions.remove(s.id)
}

// MARK: Lifecycle

func sessionOptions(text string) (*libsharing.SessionOptions, error) {
	options := libsharing.NewSessionOptions()
	if err := decodeInto(text, options); err != nil {
		return nil, err
	}
	return options, nil
}

//export aosgo_session_new
func aosgo_session_new(optionsJSON *C.char, callback C.aosgo_session_fn, out **C.char) (result C.int64_t) {
	defer guard(out)
	result = -1
	if callback == nil {
		fail(out, errors.New("aosgo: the session callback is NULL"))
		return
	}
	options, err := sessionOptions(goString(optionsJSON))
	if err != nil {
		fail(out, err)
		return
	}
	s := &session{callback: callback, transfers: map[int64]*libsharing.FileTransfer{}}
	s.session, err = libsharing.NewSession(options, s)
	if err != nil {
		fail(out, err)
		return
	}
	s.id = sessions.add(s)
	return C.int64_t(s.id)
}

//export aosgo_session_connect
func aosgo_session_connect(handle C.int64_t, out **C.char) (result C.int32_t) {
	defer guard(out)
	s, err := lookup(handle)
	if err != nil {
		return status(out, err)
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.freed {
		return status(out, errors.New("aosgo: the session was freed"))
	}
	if err := s.session.Connect(); err != nil {
		return status(out, err)
	}
	s.running = true
	return 0
}

//export aosgo_session_disconnect
func aosgo_session_disconnect(handle C.int64_t) {
	defer guard(nil)
	if s, err := lookup(handle); err == nil {
		s.session.Disconnect()
	}
}

//export aosgo_session_abort
func aosgo_session_abort(handle C.int64_t) {
	defer guard(nil)
	if s, err := lookup(handle); err == nil {
		s.session.Abort()
	}
}

//export aosgo_session_free
func aosgo_session_free(handle C.int64_t) {
	defer guard(nil)
	s, err := lookup(handle)
	if err != nil {
		return
	}
	s.mu.Lock()
	s.freed = true
	running := s.running
	s.mu.Unlock()
	if !running {
		s.release()
		return
	}
	// Its DISCONNECTED event releases it (OnStateChanged).
	s.session.Abort()
}

//export aosgo_session_attach_framebuffer
func aosgo_session_attach_framebuffer(handle C.int64_t, address C.int64_t, width, height, bytesPerRow C.int32_t,
	out **C.char) C.int32_t {
	return call(handle, out, func(s *libsharing.Session) error {
		return s.AttachFramebuffer(int64(address), int32(width), int32(height), int32(bytesPerRow))
	})
}

// MARK: Input

//export aosgo_session_send_pointer
func aosgo_session_send_pointer(handle C.int64_t, x, y, buttons, clickCount C.int32_t, out **C.char) C.int32_t {
	return call(handle, out, func(s *libsharing.Session) error {
		return s.SendPointer(int32(x), int32(y), int32(buttons), int32(clickCount))
	})
}

//export aosgo_session_send_scroll
func aosgo_session_send_scroll(handle C.int64_t, x, y C.int32_t, deltaX, deltaY C.double, out **C.char) C.int32_t {
	return call(handle, out, func(s *libsharing.Session) error {
		return s.SendScroll(int32(x), int32(y), float64(deltaX), float64(deltaY))
	})
}

//export aosgo_session_send_scroll_phase
func aosgo_session_send_scroll_phase(handle C.int64_t, x, y C.int32_t, deltaX, deltaY C.double, phase C.int32_t,
	out **C.char) C.int32_t {
	return call(handle, out, func(s *libsharing.Session) error {
		return s.SendScrollPhase(int32(x), int32(y), float64(deltaX), float64(deltaY), int32(phase))
	})
}

//export aosgo_session_start_scroll_momentum
func aosgo_session_start_scroll_momentum(handle C.int64_t, x, y C.int32_t, velocityX, velocityY C.double,
	out **C.char) C.int32_t {
	return call(handle, out, func(s *libsharing.Session) error {
		return s.StartScrollMomentum(int32(x), int32(y), float64(velocityX), float64(velocityY))
	})
}

//export aosgo_session_stop_scroll_momentum
func aosgo_session_stop_scroll_momentum(handle C.int64_t) {
	call(handle, nil, func(s *libsharing.Session) error { s.StopScrollMomentum(); return nil })
}

//export aosgo_session_send_magnify
func aosgo_session_send_magnify(handle C.int64_t, x, y C.int32_t, magnification C.double, phase C.int32_t,
	out **C.char) C.int32_t {
	return call(handle, out, func(s *libsharing.Session) error {
		return s.SendMagnify(int32(x), int32(y), float64(magnification), int32(phase))
	})
}

//export aosgo_session_send_rotate
func aosgo_session_send_rotate(handle C.int64_t, x, y C.int32_t, degrees C.double, phase C.int32_t,
	out **C.char) C.int32_t {
	return call(handle, out, func(s *libsharing.Session) error {
		return s.SendRotate(int32(x), int32(y), float64(degrees), int32(phase))
	})
}

//export aosgo_session_send_key
func aosgo_session_send_key(handle C.int64_t, keysym, down C.int32_t, out **C.char) C.int32_t {
	return call(handle, out, func(s *libsharing.Session) error { return s.SendKey(int32(keysym), goBool(down)) })
}

//export aosgo_session_send_key_code
func aosgo_session_send_key_code(handle C.int64_t, keyCode, keyboardType, keysym, down C.int32_t,
	out **C.char) C.int32_t {
	return call(handle, out, func(s *libsharing.Session) error {
		return s.SendKeyCode(int32(keyCode), int32(keyboardType), int32(keysym), goBool(down))
	})
}

//export aosgo_session_send_text
func aosgo_session_send_text(handle C.int64_t, text *C.char, out **C.char) C.int32_t {
	value := goString(text)
	return call(handle, out, func(s *libsharing.Session) error { return s.SendText(value) })
}

//export aosgo_session_paste_text
func aosgo_session_paste_text(handle C.int64_t, text *C.char, out **C.char) C.int32_t {
	value := goString(text)
	return call(handle, out, func(s *libsharing.Session) error { return s.PasteText(value) })
}

//export aosgo_session_send_system_command
func aosgo_session_send_system_command(handle C.int64_t, command C.int32_t, out **C.char) C.int32_t {
	return call(handle, out, func(s *libsharing.Session) error { return s.SendSystemCommand(int32(command)) })
}

//export aosgo_session_set_assist_cursor
func aosgo_session_set_assist_cursor(handle C.int64_t, x, y, pressed C.int32_t, out **C.char) C.int32_t {
	return call(handle, out, func(s *libsharing.Session) error {
		return s.SetAssistCursor(int32(x), int32(y), goBool(pressed))
	})
}

//export aosgo_session_hide_assist_cursor
func aosgo_session_hide_assist_cursor(handle C.int64_t, out **C.char) C.int32_t {
	return call(handle, out, func(s *libsharing.Session) error { return s.HideAssistCursor() })
}

// MARK: Clipboard

func bytesFrom(data unsafe.Pointer, length C.int64_t) []byte {
	if data == nil || length <= 0 {
		return nil
	}
	return unsafe.Slice((*byte)(data), int(length))
}

//export aosgo_session_set_clipboard
func aosgo_session_set_clipboard(handle C.int64_t, clipboardJSON *C.char, data unsafe.Pointer, length C.int64_t,
	out **C.char) C.int32_t {
	return call(handle, out, func(s *libsharing.Session) error {
		clipboard, err := clipboardFrom(goString(clipboardJSON), bytesFrom(data, length))
		if err != nil {
			return err
		}
		return s.SetClipboard(clipboard)
	})
}

//export aosgo_session_paste_clipboard
func aosgo_session_paste_clipboard(handle C.int64_t, clipboardJSON *C.char, data unsafe.Pointer, length C.int64_t,
	out **C.char) C.int32_t {
	return call(handle, out, func(s *libsharing.Session) error {
		clipboard, err := clipboardFrom(goString(clipboardJSON), bytesFrom(data, length))
		if err != nil {
			return err
		}
		return s.PasteClipboard(clipboard)
	})
}

//export aosgo_session_set_clipboard_text
func aosgo_session_set_clipboard_text(handle C.int64_t, text *C.char, out **C.char) C.int32_t {
	value := goString(text)
	return call(handle, out, func(s *libsharing.Session) error {
		item := libsharing.NewClipboardItem()
		item.AddFlavor(utf8PlainText, []byte(value))
		clipboard := libsharing.NewClipboard()
		clipboard.AddItem(item)
		return s.SetClipboard(clipboard)
	})
}

//export aosgo_session_request_clipboard
func aosgo_session_request_clipboard(handle C.int64_t, out **C.char) C.int32_t {
	return call(handle, out, func(s *libsharing.Session) error { return s.RequestClipboard() })
}

//export aosgo_session_set_shared_clipboard
func aosgo_session_set_shared_clipboard(handle C.int64_t, enabled C.int32_t, out **C.char) C.int32_t {
	return call(handle, out, func(s *libsharing.Session) error { return s.SetSharedClipboard(goBool(enabled)) })
}

// MARK: Screen and session

//export aosgo_session_set_virtual_display
func aosgo_session_set_virtual_display(handle C.int64_t, width, height C.int32_t, density C.double,
	maximumWidth, maximumHeight C.int32_t, out **C.char) C.int32_t {
	return call(handle, out, func(s *libsharing.Session) error {
		return s.SetVirtualDisplay(int32(width), int32(height), float64(density), int32(maximumWidth),
			int32(maximumHeight))
	})
}

//export aosgo_session_display_width_multiple
func aosgo_session_display_width_multiple(handle C.int64_t) (result C.int32_t) {
	defer guard(nil)
	result = 1
	if s, err := lookup(handle); err == nil {
		result = C.int32_t(max(s.session.DisplayWidthMultiple(), 1))
	}
	return
}

//export aosgo_session_select_display
func aosgo_session_select_display(handle C.int64_t, displayID C.int64_t, out **C.char) C.int32_t {
	return call(handle, out, func(s *libsharing.Session) error { return s.SelectDisplay(int64(displayID)) })
}

//export aosgo_session_set_quality
func aosgo_session_set_quality(handle C.int64_t, quality C.int32_t, out **C.char) C.int32_t {
	return call(handle, out, func(s *libsharing.Session) error { return s.SetQuality(int32(quality)) })
}

//export aosgo_session_set_mode
func aosgo_session_set_mode(handle C.int64_t, mode C.int32_t, out **C.char) C.int32_t {
	return call(handle, out, func(s *libsharing.Session) error { return s.SetMode(int32(mode)) })
}

//export aosgo_session_set_update_rate
func aosgo_session_set_update_rate(handle C.int64_t, rate C.int32_t, out **C.char) C.int32_t {
	return call(handle, out, func(s *libsharing.Session) error { return s.SetUpdateRate(int32(rate)) })
}

//export aosgo_session_set_visible
func aosgo_session_set_visible(handle C.int64_t, visible C.int32_t, out **C.char) C.int32_t {
	return call(handle, out, func(s *libsharing.Session) error { return s.SetVisible(goBool(visible)) })
}

//export aosgo_session_select_keyboard_source
func aosgo_session_select_keyboard_source(handle C.int64_t, sourceID *C.char, out **C.char) C.int32_t {
	value := goString(sourceID)
	return call(handle, out, func(s *libsharing.Session) error { return s.SelectKeyboardSource(value) })
}

//export aosgo_session_request_refresh
func aosgo_session_request_refresh(handle C.int64_t, out **C.char) C.int32_t {
	return call(handle, out, func(s *libsharing.Session) error { return s.RequestRefresh() })
}

//export aosgo_session_answer_prompt
func aosgo_session_answer_prompt(handle C.int64_t, promptID C.int64_t, answer C.int32_t, out **C.char) C.int32_t {
	return call(handle, out, func(s *libsharing.Session) error { return s.AnswerPrompt(int64(promptID), int32(answer)) })
}

//export aosgo_session_statistics
func aosgo_session_statistics(handle C.int64_t, out **C.char) (result *C.char) {
	defer guard(out)
	s, err := lookup(handle)
	if err != nil {
		fail(out, err)
		return nil
	}
	return C.CString(jsonText(object(s.session.Statistics())))
}

// MARK: High performance

func highPerformanceOptions(text string) (*libsharing.HighPerformanceOptions, error) {
	options := libsharing.NewHighPerformanceOptions()
	if err := decodeInto(text, options); err != nil {
		return nil, err
	}
	return options, nil
}

//export aosgo_session_start_high_performance
func aosgo_session_start_high_performance(handle C.int64_t, optionsJSON *C.char, out **C.char) C.int32_t {
	text := goString(optionsJSON)
	return call(handle, out, func(s *libsharing.Session) error {
		options, err := highPerformanceOptions(text)
		if err != nil {
			return err
		}
		return s.StartHighPerformance(options)
	})
}

//export aosgo_session_restart_high_performance
func aosgo_session_restart_high_performance(handle C.int64_t, optionsJSON *C.char, out **C.char) C.int32_t {
	text := goString(optionsJSON)
	return call(handle, out, func(s *libsharing.Session) error {
		options, err := highPerformanceOptions(text)
		if err != nil {
			return err
		}
		return s.RestartHighPerformance(options)
	})
}

//export aosgo_session_set_hdr
func aosgo_session_set_hdr(handle C.int64_t, enabled C.int32_t, out **C.char) C.int32_t {
	return call(handle, out, func(s *libsharing.Session) error { return s.SetHDR(goBool(enabled)) })
}

//export aosgo_session_request_keyframe
func aosgo_session_request_keyframe(handle C.int64_t, out **C.char) C.int32_t {
	return call(handle, out, func(s *libsharing.Session) error { return s.RequestKeyframe() })
}

// MARK: Files and drag and drop

func (s *session) startTransfer(out **C.char, transfer *libsharing.FileTransfer, err error) C.int64_t {
	if err != nil {
		fail(out, err)
		return -1
	}
	id := transfer.TransferID()
	s.mu.Lock()
	s.transfers[id] = transfer
	s.mu.Unlock()
	return C.int64_t(id)
}

//export aosgo_session_upload_file
func aosgo_session_upload_file(handle C.int64_t, localPath, remoteFolder *C.char, out **C.char) (result C.int64_t) {
	defer guard(out)
	result = -1
	s, err := lookup(handle)
	if err != nil {
		fail(out, err)
		return
	}
	transfer, err := s.session.UploadFile(goString(localPath), goString(remoteFolder))
	return s.startTransfer(out, transfer, err)
}

//export aosgo_session_download_file
func aosgo_session_download_file(handle C.int64_t, remotePath, localFolder *C.char, out **C.char) (result C.int64_t) {
	defer guard(out)
	result = -1
	s, err := lookup(handle)
	if err != nil {
		fail(out, err)
		return
	}
	transfer, err := s.session.DownloadFile(goString(remotePath), goString(localFolder))
	return s.startTransfer(out, transfer, err)
}

//export aosgo_session_download_files
func aosgo_session_download_files(handle C.int64_t, remotePaths, localFolder *C.char, out **C.char) C.int32_t {
	paths, folder := goString(remotePaths), goString(localFolder)
	return call(handle, out, func(s *libsharing.Session) error { return s.DownloadFiles(paths, folder) })
}

//export aosgo_session_cancel_transfer
func aosgo_session_cancel_transfer(handle C.int64_t, transferID C.int64_t, out **C.char) (result C.int32_t) {
	defer guard(out)
	s, err := lookup(handle)
	if err != nil {
		return status(out, err)
	}
	s.mu.Lock()
	transfer := s.transfers[int64(transferID)]
	s.mu.Unlock()
	if transfer == nil {
		return status(out, fmt.Errorf("aosgo: no transfer %d", int64(transferID)))
	}
	return status(out, transfer.Cancel())
}

//export aosgo_session_start_drop
func aosgo_session_start_drop(handle C.int64_t, names *C.char, out **C.char) (result C.int64_t) {
	defer guard(out)
	result = -1
	s, err := lookup(handle)
	if err != nil {
		fail(out, err)
		return
	}
	id, err := s.session.StartDrop(goString(names))
	if err != nil {
		fail(out, err)
		return
	}
	return C.int64_t(id)
}

//export aosgo_session_cancel_drag
func aosgo_session_cancel_drag(handle C.int64_t, dragID C.int64_t, out **C.char) C.int32_t {
	return call(handle, out, func(s *libsharing.Session) error { return s.CancelDrag(int64(dragID)) })
}

//export aosgo_session_cancel_remote_drag
func aosgo_session_cancel_remote_drag(handle C.int64_t, out **C.char) C.int32_t {
	return call(handle, out, func(s *libsharing.Session) error { return s.CancelRemoteDrag() })
}

// MARK: Probes

//export aosgo_check_login
func aosgo_check_login(optionsJSON *C.char, out **C.char) *C.char {
	defer guard(out)
	options, err := sessionOptions(goString(optionsJSON))
	if err != nil {
		fail(out, err)
		return nil
	}
	return C.CString(jsonText(object(libsharing.NewProbeRequest().CheckLogin(options))))
}

//export aosgo_probe_server
func aosgo_probe_server(host *C.char, port C.int32_t, out **C.char) *C.char {
	defer guard(out)
	return C.CString(jsonText(object(libsharing.NewProbeRequest().ProbeServer(goString(host), int32(port)))))
}
