// aosgo: the Go library of aOS's desktop companion (Windows, Linux; macOS for testing) as a C shared library
// (aosgo.dll, libaosgo.so, libaosgo.dylib). One library with one Go runtime holds both of the Android app's Go
// packages: libsharing (Open Screen Sharing's screen engine, GPL-3.0) and tailnetkit (aOS's Tailscale node).
// Android/third_party/aosgo-desktop/README.md describes it; kotlin/AosGo.kt is the JNA binding.
//
// This file is part of aOS's desktop wrapper of Open Screen Sharing's libsharing and is GPL-3.0 like it (Open Screen
// Sharing by nekohasekai, GPL-3.0; iOS/ThirdParty/OpenScreenSharing/LICENSE and COPYING in aOS). The library built
// from it is GPL-3.0 as a whole.
//
// Conventions
// - Handles (sessions, nodes) are > 0. A handle that is unknown (freed, closed, never made) fails like an error.
// - Functions that can fail return -1 (int32_t/int64_t) or NULL and, when `error` is not NULL, store a message there
//   that the caller frees with aosgo_free. On success *error is left alone (set it to NULL before the call).
// - Strings in either direction are UTF-8 and NUL-terminated. Strings the library returns are the caller's: free
//   them with aosgo_free. Strings the library receives are only read during the call (no `const` because cgo can't
//   export it).
// - Booleans are int32_t: 0 false, anything else true.
// - Every function may be called from any thread. Calls that talk to the network block (see each one): don't call
//   them on a UI thread.
// - Callbacks run on the library's own threads (Go threads), never on a thread of the caller. A callback blocks the
//   part of the library that called it: return quickly. Pointers a callback receives (text, data) are valid only
//   until it returns: copy what you keep. A callback may call any function of this library, except that freeing
//   the handle it reports for (aosgo_session_free, aosgo_tailnet_close) from inside it only marks it (see there).
// - JSON: objects with lowerCamel keys named like the gomobile getters of the Android library (Libsharing's
//   SessionOptions.requireTrustedKey -> "requireTrustedKey"). Input objects may leave out keys (defaults apply);
//   unknown keys are an error. Output objects may gain keys in later versions: ignore unknown ones.

#ifndef AOSGO_H
#define AOSGO_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// MARK: Library

/// Frees a string (or other memory) the library returned. NULL is fine.
void aosgo_free(void *pointer);
/// What this library was built from (Open Screen Sharing's commit, the patches' hashes, Tailnet's files, Go): the
/// corresponding source for GPL-3.0. Free it.
char *aosgo_version(void);

/// libsharing's log: level is slog's (-4 debug, 0 info, 4 warn, 8 error), message one line. Host names may be in it.
typedef void (*aosgo_log_fn)(int32_t level, const char *message);
/// Sends libsharing's log of sessions created after this call, at minimum_level and above, to fn (NULL: none).
void aosgo_set_log_handler(aosgo_log_fn fn, int32_t minimum_level);

// MARK: libsharing: constants (the same values as Libsharing.* on Android)

#define AOSGO_PROTOCOL_RFB 0
#define AOSGO_PROTOCOL_RDP 1

#define AOSGO_PLATFORM_UNKNOWN 0
#define AOSGO_PLATFORM_MAC 1
#define AOSGO_PLATFORM_PC 2

#define AOSGO_LOGIN_ACCOUNT 0
#define AOSGO_LOGIN_REQUEST_CONTROL 1
#define AOSGO_LOGIN_REQUEST_OBSERVE 2
#define AOSGO_LOGIN_VNC_PASSWORD 3
#define AOSGO_LOGIN_NONE 4

#define AOSGO_QUALITY_ADAPTIVE 0
#define AOSGO_QUALITY_FULL 1
#define AOSGO_QUALITY_HIGH 2
#define AOSGO_QUALITY_MEDIUM 3
#define AOSGO_QUALITY_LOW 4

#define AOSGO_MODE_OBSERVE 0
#define AOSGO_MODE_CONTROL 1
#define AOSGO_MODE_EXCLUSIVE_CONTROL 2

#define AOSGO_DIALECT_APPLE 1
#define AOSGO_DIALECT_STANDARD 2
#define AOSGO_DIALECT_RDP 3

#define AOSGO_KEYBOARD_ANSI 40
#define AOSGO_KEYBOARD_ISO 41
#define AOSGO_KEYBOARD_JIS 42

#define AOSGO_STATE_CONNECTING 1
#define AOSGO_STATE_AUTHENTICATING 2
#define AOSGO_STATE_WAITING_FOR_APPROVAL 3
#define AOSGO_STATE_CHOOSING_SESSION 4
#define AOSGO_STATE_CONNECTED 5
#define AOSGO_STATE_DISCONNECTED 6

#define AOSGO_ERROR_NONE 0
#define AOSGO_ERROR_AUTHENTICATION 1
#define AOSGO_ERROR_PERMISSION_DENIED 2
#define AOSGO_ERROR_NETWORK 3
#define AOSGO_ERROR_PROTOCOL 4
#define AOSGO_ERROR_CANCELLED 5
#define AOSGO_ERROR_UNSUPPORTED_SERVER 6
#define AOSGO_ERROR_UNVERIFIED_SERVER 7
#define AOSGO_ERROR_SESSION_ENDED 8
#define AOSGO_ERROR_HOST_NOT_FOUND 9
#define AOSGO_ERROR_OWN_SCREEN 10
#define AOSGO_ERROR_CERTIFICATE_CHANGED 11

#define AOSGO_BUTTON_LEFT 1
#define AOSGO_BUTTON_MIDDLE 2
#define AOSGO_BUTTON_RIGHT 4

#define AOSGO_CLIPBOARD_PROBLEM_NOT_RESTORED 2

#define AOSGO_SESSION_CHOICE_CANCEL (-1)
#define AOSGO_SESSION_CHOICE_SHARE_CONSOLE 0
#define AOSGO_SESSION_CHOICE_OWN_SESSION 2

#define AOSGO_STATUS_CONTROL_ALLOWED 9
#define AOSGO_STATUS_OBSERVE_ONLY 10
#define AOSGO_STATUS_POINTER_HIDDEN 11
#define AOSGO_STATUS_POINTER_SHOWN 12

#define AOSGO_ALL_DISPLAYS 0

#define AOSGO_GESTURE_PHASE_BEGAN 1
#define AOSGO_GESTURE_PHASE_CHANGED 2
#define AOSGO_GESTURE_PHASE_ENDED 4
#define AOSGO_GESTURE_PHASE_CANCELLED 8
#define AOSGO_GESTURE_PHASE_MAY_BEGIN 0x80

#define AOSGO_SYSTEM_COMMAND_MISSION_CONTROL 1
#define AOSGO_SYSTEM_COMMAND_APP_WINDOWS 2
#define AOSGO_SYSTEM_COMMAND_SHOW_DESKTOP 3
#define AOSGO_SYSTEM_COMMAND_LAUNCHPAD 4

#define AOSGO_CODEC_HEVC 1
#define AOSGO_CODEC_H264 2
#define AOSGO_DECODER_CODEC_HEVC (1 << 0)
#define AOSGO_DECODER_CODEC_H264 (1 << 1)

#define AOSGO_MEDIA_ERROR_NONE 0
#define AOSGO_MEDIA_ERROR_BUSY 1
#define AOSGO_MEDIA_ERROR_REFUSED 2
#define AOSGO_MEDIA_ERROR_SILENT 3
#define AOSGO_MEDIA_ERROR_NETWORK 4

#define AOSGO_VIDEO_MODE_CORE_DEVICE 5
#define AOSGO_VIDEO_MODE_REMOTE_DESKTOP 7

#define AOSGO_FILE_ERROR_NONE 0
#define AOSGO_FILE_ERROR_CANCELLED 1
#define AOSGO_FILE_ERROR_NOT_ALLOWED 2
#define AOSGO_FILE_ERROR_NOT_FOUND 3
#define AOSGO_FILE_ERROR_NOT_WRITABLE 4
#define AOSGO_FILE_ERROR_DISK_FULL 5
#define AOSGO_FILE_ERROR_PERMISSION 6
#define AOSGO_FILE_ERROR_LOCAL 7
#define AOSGO_FILE_ERROR_CONNECTION 8
#define AOSGO_FILE_ERROR_FAILED 9
#define AOSGO_FILE_ERROR_OBSERVE_ONLY 10
#define AOSGO_FILE_ERROR_UNSUPPORTED 11

// MARK: libsharing: session events
//
// One callback per session receives every event (Android's SessionHandler, one method per event):
//   kind      an AOSGO_EVENT_* below
//   a ... e   numbers, their meaning per kind (unused ones are 0)
//   text      UTF-8 text or a JSON object (per kind), or NULL
//   data      bytes (per kind), or NULL; length is their count
// Events of one session come in order from the session's thread; video and audio from the media stream's threads.

typedef void (*aosgo_session_fn)(int64_t session, int32_t kind, int64_t a, int64_t b, int64_t c, int64_t d,
                                 int64_t e, const char *text, const void *data, int64_t length);

/// a state (AOSGO_STATE_*), b error (AOSGO_ERROR_*, with DISCONNECTED), text message.
/// DISCONNECTED is the session's last event (until it connects again).
#define AOSGO_EVENT_STATE 1
/// text JSON ServerInfo: width, height, dialect, platform, cursorPixelsPerPoint, observeOnly, supports... (all of
/// Android's ServerInfo getters, e.g. supportsHighPerformance, supportsVirtualDisplay, supportsKeyCodes).
#define AOSGO_EVENT_SERVER_INFO 2
/// text the server's certificate or key fingerprint.
#define AOSGO_EVENT_SERVER_CERTIFICATE 3
/// a width, b height. Before the first picture and on every size change. The callback MUST attach a framebuffer of
/// exactly this size (aosgo_session_attach_framebuffer) before it returns, or the session fails.
#define AOSGO_EVENT_FRAMEBUFFER_RESIZE 4
/// a x, b y, c width, d height: that rectangle of the framebuffer is complete. e hold nanoseconds (statistics).
#define AOSGO_EVENT_FRAMEBUFFER_UPDATE 5
/// a width, b height, c hotspot x, d hotspot y, e invert mask length. data: width*height*4 bytes of pixels (B, G, R,
/// A in memory), then the e bytes of the invert mask. A width or height of 0: no cursor image.
#define AOSGO_EVENT_CURSOR_IMAGE 6
/// a x, b y.
#define AOSGO_EVENT_CURSOR_POSITION 7
/// text JSON: current, framebufferWidth, desktopWidth, displays: [{displayID, logicalWidth, logicalHeight, isMain,
/// isVirtual}].
#define AOSGO_EVENT_DISPLAYS 8
/// The server's clipboard. text JSON: items: [{flavors: [{type, promise, offset, length}]}]; each flavor's bytes are
/// data[offset, offset+length). Plain text is type "public.utf8-plain-text".
#define AOSGO_EVENT_CLIPBOARD 9
/// a kind (AOSGO_CLIPBOARD_PROBLEM_*), text message.
#define AOSGO_EVENT_CLIPBOARD_PROBLEM 10
/// No values.
#define AOSGO_EVENT_BELL 11
/// a secure input (0/1), text the input source id.
#define AOSGO_EVENT_KEYBOARD_SOURCE 12
/// a status (AOSGO_STATUS_*).
#define AOSGO_EVENT_STATUS 13
/// The Mac asks which session to use. a prompt id, b allows share console (0/1), c allows own session (0/1), text
/// the console user. The session waits for aosgo_session_answer_prompt (from any thread, after the callback too).
#define AOSGO_EVENT_PROMPT 14
/// a codec (AOSGO_CODEC_*), b bands, c height (all bands), d chroma format (1 4:2:0, 3 4:4:4), e HDR (0/1). data:
/// the parameter sets (HEVC VPS, SPS, PPS; H.264 SPS, PPS) in stream order, each as a 4 byte big-endian length and
/// the raw NAL unit. Comes before the first access unit and whenever the stream changes.
#define AOSGO_EVENT_VIDEO_FORMAT 15
/// data: one access unit as length-prefixed NAL units (4 byte big-endian lengths), without parameter sets. text
/// JSON: timestamp, clockRate, sync, band, bands, frameID, frameEnd, changedBands, discontinuity, turns,
/// holdNanoseconds, composed, composeNanoseconds (Android's VideoAccessUnit getters). a timestamp, b clock rate,
/// c sync (0/1), d discontinuity (0/1), e frame end (0/1) for a quick look.
#define AOSGO_EVENT_VIDEO_ACCESS_UNIT 16
/// a format id (Core Audio), b sample rate, c channels, d frames per packet; data the magic cookie.
#define AOSGO_EVENT_AUDIO_FORMAT 17
/// a timestamp, b lost packets; data the packet.
#define AOSGO_EVENT_AUDIO_PACKET 18
/// The Mac wants the microphone in this format: like AUDIO_FORMAT.
#define AOSGO_EVENT_MICROPHONE 19
/// a error (AOSGO_MEDIA_ERROR_*), text message: the high performance stream ended.
#define AOSGO_EVENT_MEDIA_STOPPED 20
/// a transfer id, b bytes transferred, c total bytes.
#define AOSGO_EVENT_FILE_TRANSFER_PROGRESS 21
/// a transfer id, b error (AOSGO_FILE_ERROR_*), text JSON: name, message.
#define AOSGO_EVENT_FILE_TRANSFER_FINISHED 22
/// a drag id, text the destination path on the Mac.
#define AOSGO_EVENT_DROP_DESTINATION 23
/// text JSON: items: [{path, isFolder}] (NULL: the drag ended); data the drag image, if any.
#define AOSGO_EVENT_REMOTE_DRAG 24
/// text JSON: model, deviceColor, enclosureColor.
#define AOSGO_EVENT_DEVICE_INFO 25

// MARK: libsharing: sessions

/// A session (Libsharing.newSession). options_json: SessionOptions, defaults as Libsharing.newSessionOptions()
/// (port 5900, loginType account, quality adaptive, mode control, sharedClipboard true): protocol, host, port,
/// username, password, trustedFingerprint, requireTrustedKey, allowUnverifiedLogin, keyboardLayout, audio,
/// microphone, loginType, quality, mode, sharedClipboard, clientName, platform, decoderMaxPixelRate,
/// maximumFrameRate, updateRate, keepAlive, disableUDP, cacheDirectory. callback must not be NULL and must stay
/// valid until the handle is gone (after aosgo_session_free and the session's DISCONNECTED event).
int64_t aosgo_session_new(char *options_json, aosgo_session_fn callback, char **error);
/// Connects in the background: returns at once, progress comes as STATE events.
int32_t aosgo_session_connect(int64_t session, char **error);
/// Ends the session in the background (DISCONNECTED comes when it has ended).
void aosgo_session_disconnect(int64_t session);
/// Ends it at once, without saying goodbye to the server.
void aosgo_session_abort(int64_t session);
/// Releases the handle. A session that still runs is aborted first; its DISCONNECTED event still comes (so the app
/// knows when the framebuffer is free), then the handle is gone. A session that never connected or has ended goes at
/// once. From inside the session's callback it only marks the session; it goes after the callback.
void aosgo_session_free(int64_t session);

/// Hands libsharing the memory it draws the remote screen into: width*height pixels of 4 bytes, memory order B, G,
/// R, X (X undefined, draw opaque), rows bytes_per_row apart (>= 4*width), top row first. address is a plain
/// pointer (JNA: Pointer.nativeValue(memory); Skia: a Pixmap's address).
/// - Call it inside the FRAMEBUFFER_RESIZE callback with exactly that size; outside one (a connected session) it
///   replaces the framebuffer at once; before connecting it fails ("not connected").
/// - libsharing writes into the memory from its own thread at any time until (a) another framebuffer was attached
///   AND the FRAMEBUFFER_RESIZE callback that attached it returned, or (b) the session's DISCONNECTED event came.
///   Keep the memory valid until then; free it earlier and libsharing writes into freed memory.
/// - After a FRAMEBUFFER_UPDATE event the rectangle in it is complete; libsharing may already write the next one
///   while you read (take what's there, the next update repairs it).
int32_t aosgo_session_attach_framebuffer(int64_t session, int64_t address, int32_t width, int32_t height,
                                         int32_t bytes_per_row, char **error);

/// Input. buttons: AOSGO_BUTTON_* bits; click_count 1, 2, 3 for single, double, triple clicks.
int32_t aosgo_session_send_pointer(int64_t session, int32_t x, int32_t y, int32_t buttons, int32_t click_count,
                                   char **error);
int32_t aosgo_session_send_scroll(int64_t session, int32_t x, int32_t y, double delta_x, double delta_y, char **error);
/// Trackpad-style scrolling: phase AOSGO_GESTURE_PHASE_*.
int32_t aosgo_session_send_scroll_phase(int64_t session, int32_t x, int32_t y, double delta_x, double delta_y,
                                        int32_t phase, char **error);
int32_t aosgo_session_start_scroll_momentum(int64_t session, int32_t x, int32_t y, double velocity_x, double velocity_y,
                                            char **error);
void aosgo_session_stop_scroll_momentum(int64_t session);
int32_t aosgo_session_send_magnify(int64_t session, int32_t x, int32_t y, double magnification, int32_t phase,
                                   char **error);
int32_t aosgo_session_send_rotate(int64_t session, int32_t x, int32_t y, double degrees, int32_t phase, char **error);
/// An X11 keysym, down or up.
int32_t aosgo_session_send_key(int64_t session, int32_t keysym, int32_t down, char **error);
/// A Mac virtual key code (keyboard_type AOSGO_KEYBOARD_*) with its keysym, down or up (needs supportsKeyCodes).
int32_t aosgo_session_send_key_code(int64_t session, int32_t key_code, int32_t keyboard_type, int32_t keysym,
                                    int32_t down, char **error);
/// Types text (Unicode).
int32_t aosgo_session_send_text(int64_t session, char *text, char **error);
/// Puts text on the Mac's clipboard and pastes it.
int32_t aosgo_session_paste_text(int64_t session, char *text, char **error);
/// AOSGO_SYSTEM_COMMAND_*.
int32_t aosgo_session_send_system_command(int64_t session, int32_t command, char **error);
int32_t aosgo_session_set_assist_cursor(int64_t session, int32_t x, int32_t y, int32_t pressed, char **error);
int32_t aosgo_session_hide_assist_cursor(int64_t session, char **error);

/// Clipboard. clipboard_json and data like the CLIPBOARD event (items, flavors with type and offset/length into
/// data; promise is ignored).
int32_t aosgo_session_set_clipboard(int64_t session, char *clipboard_json, void *data, int64_t length, char **error);
/// Puts the clipboard on the Mac and pastes it.
int32_t aosgo_session_paste_clipboard(int64_t session, char *clipboard_json, void *data, int64_t length,
                                      char **error);
/// Sets the Mac's clipboard to plain text (one item, "public.utf8-plain-text").
int32_t aosgo_session_set_clipboard_text(int64_t session, char *text, char **error);
/// Asks for the Mac's clipboard (it comes as a CLIPBOARD event).
int32_t aosgo_session_request_clipboard(int64_t session, char **error);
int32_t aosgo_session_set_shared_clipboard(int64_t session, int32_t enabled, char **error);

/// Screen and session.
int32_t aosgo_session_set_virtual_display(int64_t session, int32_t width, int32_t height, double density,
                                          int32_t maximum_width, int32_t maximum_height, char **error);
/// The width a virtual display's width must be a multiple of (>= 1).
int32_t aosgo_session_display_width_multiple(int64_t session);
int32_t aosgo_session_select_display(int64_t session, int64_t display_id, char **error);
int32_t aosgo_session_set_quality(int64_t session, int32_t quality, char **error);
int32_t aosgo_session_set_mode(int64_t session, int32_t mode, char **error);
int32_t aosgo_session_set_update_rate(int64_t session, int32_t rate, char **error);
int32_t aosgo_session_set_visible(int64_t session, int32_t visible, char **error);
int32_t aosgo_session_select_keyboard_source(int64_t session, char *source_id, char **error);
int32_t aosgo_session_request_refresh(int64_t session, char **error);
/// answer: AOSGO_SESSION_CHOICE_*.
int32_t aosgo_session_answer_prompt(int64_t session, int64_t prompt_id, int32_t answer, char **error);
/// JSON Statistics: roundTripMilliseconds, receivedBytes, encoding, highPerformance, udp, packets, packetsExpected,
/// videoLosses. Free it.
char *aosgo_session_statistics(int64_t session, char **error);

/// High performance (encoded video). options_json: HighPerformanceOptions, defaults as
/// Libsharing.newHighPerformanceOptions() (supportedCodecs HEVC, audio true, bands 1): supportedCodecs
/// (AOSGO_DECODER_CODEC_* bits), pixelFormats (bits: 0 4:2:0 8 bit full range, 1 video range, 3 and 4 4:4:4, 5 10 bit
/// 4:4:4 HDR), audio, bands, videoMode (AOSGO_VIDEO_MODE_*), immediatePlayout. Before connecting too (kept until
/// connected).
int32_t aosgo_session_start_high_performance(int64_t session, char *options_json, char **error);
int32_t aosgo_session_restart_high_performance(int64_t session, char *options_json, char **error);
int32_t aosgo_session_set_hdr(int64_t session, int32_t enabled, char **error);
int32_t aosgo_session_request_keyframe(int64_t session, char **error);

/// Files. Uploads a local file into a folder on the Mac ("" = ~/Desktop) / downloads a file of the Mac into a local
/// folder: returns the transfer id (progress and end come as FILE_TRANSFER_* events), or -1.
int64_t aosgo_session_upload_file(int64_t session, char *local_path, char *remote_folder, char **error);
int64_t aosgo_session_download_file(int64_t session, char *remote_path, char *local_folder, char **error);
/// Downloads several files (paths separated by "\n") and blocks until all are there.
int32_t aosgo_session_download_files(int64_t session, char *remote_paths, char *local_folder, char **error);
int32_t aosgo_session_cancel_transfer(int64_t session, int64_t transfer_id, char **error);
/// Drag and drop: names separated by "\n"; returns the drag id, or -1.
int64_t aosgo_session_start_drop(int64_t session, char *names, char **error);
int32_t aosgo_session_cancel_drag(int64_t session, int64_t drag_id, char **error);
int32_t aosgo_session_cancel_remote_drag(int64_t session, char **error);

/// Logs in once and disconnects (ProbeRequest.checkLogin): JSON LoginCheck: supportsHighPerformance, fingerprint,
/// security, errorCode (AOSGO_ERROR_*), errorMessage. Blocks (network). options_json as for aosgo_session_new.
char *aosgo_check_login(char *options_json, char **error);
/// What a server offers (ProbeRequest.probeServer): JSON ServerProbe. Blocks (network).
char *aosgo_probe_server(char *host, int32_t port, char **error);

// MARK: tailnetkit: aOS's Tailscale node (Android's dev.marquart.aos.tailnetkit)

/// 1 if built with aOS's build tags (the node offers nothing on the tailnet); aosgo_tailnet_new refuses otherwise.
int32_t aosgo_tailnet_built_for_aos(void);
/// 1 if url is https on tailscale.com or *.tailscale.com (only such sign-in pages should open).
int32_t aosgo_tailnet_is_sign_in_page(char *url);

/// The node's verbose log, one line (URLs replaced by "<url>").
typedef void (*aosgo_tailnet_log_fn)(int64_t node, const char *line);
/// A new state, as JSON like aosgo_tailnet_state's.
typedef void (*aosgo_tailnet_state_fn)(int64_t node, const char *state_json);

/// A node with its state in dir (absolute; created 0700; keep it out of backups and other users' reach), hostname a
/// DNS label (aOS uses "aos-<device name>"), control_url "" for Tailscale's server, log NULL or a sink. log must
/// stay valid until aosgo_tailnet_close.
int64_t aosgo_tailnet_new(char *dir, char *hostname, char *control_url, aosgo_tailnet_log_fn log, char **error);
/// Starts the node without waiting; state changes go to listener (NULL: none; one at a time, in order). A second
/// start does nothing. listener must stay valid until aosgo_tailnet_close.
int32_t aosgo_tailnet_start(int64_t node, aosgo_tailnet_state_fn listener, char **error);
/// JSON State: backendState (NoState, NeedsLogin, NeedsMachineAuth, Stopped, Starting, Running), running,
/// needsLogin, authURL (the sign-in page while needed, else ""), tailnet, magicDNSSuffix, dnsName (no final dot),
/// addresses (comma-separated, IPv4 first), keyExpiry (RFC 3339 or ""), health (one problem per line), error. Blocks
/// up to 10 seconds. Free it.
char *aosgo_tailnet_state(int64_t node, char **error);
/// Tailscale's status (`tailscale status --json`). Blocks up to 10 seconds. Free it.
char *aosgo_tailnet_status_json(int64_t node, char **error);
/// Asks for a new sign-in URL (it comes with the next state). Blocks up to 20 seconds.
int32_t aosgo_tailnet_login(int64_t node, char **error);
/// Leaves the tailnet. Then close the node and delete its dir. Blocks up to 20 seconds.
int32_t aosgo_tailnet_logout(int64_t node, char **error);
/// Connects to host:port through the tailnet, then listens once on 127.0.0.1 and returns that port: connect a TCP
/// socket there within 15 seconds and it is spliced to the tailnet connection (without one, it closes). With
/// client_port > 0 only a connection from that local port is taken (bind your socket to 127.0.0.1:0 first and pass
/// its port), so no other program can take it. Blocks until the tailnet connection stands (up to timeout_millis).
/// Returns the port or -1.
int32_t aosgo_tailnet_dial(int64_t node, char *host, int32_t port, int32_t timeout_millis, int32_t client_port,
                           char **error);
/// Stops the node and releases the handle (idempotent; also from inside its callbacks). No callbacks start after it
/// returned (one already running may finish).
void aosgo_tailnet_close(int64_t node);

#ifdef __cplusplus
}
#endif

#endif
