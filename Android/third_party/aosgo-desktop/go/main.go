// aOS: the C API of aOS's desktop companion library (aosgo.h): Open Screen Sharing's libsharing and aOS's Tailscale
// node (Tailnet/mobile) in one C shared library with one Go runtime, for the JVM app (JNA). Built by
// Android/Tools/go-desktop.sh inside a copy of Open Screen Sharing's Go module.
//
// Part of aOS's desktop wrapper of Open Screen Sharing (Android/third_party/aosgo-desktop in aOS). Based on Open
// Screen Sharing by nekohasekai, GPL-3.0; this file is GPL-3.0 too (iOS/ThirdParty/OpenScreenSharing/LICENSE and
// COPYING in aOS).

package main

/*
#include <stdlib.h>
#include "aosgo.h"

static inline void aosgo_call_log(aosgo_log_fn fn, int32_t level, const char *message) { fn(level, message); }
*/
import "C"

import (
	"bytes"
	"encoding/json"
	"fmt"
	"reflect"
	"strings"
	"sync"
	"sync/atomic"
	"unicode"
	"unsafe"

	"github.com/nekohasekai/open-screen-sharing/libsharing"
)

// source is what the library was built from; go-desktop.sh writes it into source.go (aosgo_version).
var source = "unknown"

func main() {}

// MARK: Errors and strings

// fail stores err's message in *out (if out is not NULL) for the caller to free.
func fail(out **C.char, err error) {
	if out != nil && err != nil {
		*out = C.CString(err.Error())
	}
}

// guard turns a panic in an exported function into an error instead of ending the process.
func guard(out **C.char) {
	if r := recover(); r != nil {
		fail(out, fmt.Errorf("aosgo: internal error: %v", r))
	}
}

// status is 0 for nil, else stores the error and returns -1.
func status(out **C.char, err error) C.int32_t {
	if err != nil {
		fail(out, err)
		return -1
	}
	return 0
}

func goString(s *C.char) string {
	if s == nil {
		return ""
	}
	return C.GoString(s)
}

func goBool(b C.int32_t) bool { return b != 0 }

func cBool(b bool) C.int64_t {
	if b {
		return 1
	}
	return 0
}

// cText is s as NUL-terminated bytes in Go memory, for a callback (valid while the slice lives).
func cText(s string) []byte {
	b := make([]byte, len(s)+1)
	copy(b, s)
	return b
}

func textPointer(b []byte) *C.char {
	if b == nil {
		return nil
	}
	return (*C.char)(unsafe.Pointer(&b[0]))
}

func dataPointer(b []byte) unsafe.Pointer {
	if len(b) == 0 {
		return nil
	}
	return unsafe.Pointer(&b[0])
}

//export aosgo_free
func aosgo_free(pointer unsafe.Pointer) {
	C.free(pointer)
}

//export aosgo_version
func aosgo_version() *C.char {
	return C.CString(source)
}

// MARK: JSON

// lowerCamel is a Go field name as the gomobile getters of the Android library spell it in Kotlin: the leading
// capitals in lower case except one that starts a word (HDR -> hdr, PromptID -> promptID, SupportsUDP ->
// supportsUDP, URLText -> urlText).
func lowerCamel(name string) string {
	runes := []rune(name)
	upper := 0
	for upper < len(runes) && unicode.IsUpper(runes[upper]) {
		upper++
	}
	if upper == 0 {
		return name
	}
	if upper > 1 && upper < len(runes) {
		upper-- // the last capital starts the next word
	}
	for i := 0; i < upper; i++ {
		runes[i] = unicode.ToLower(runes[i])
	}
	return string(runes)
}

// object is a struct's exported fields (not []byte ones: those travel as data) as a JSON object with lowerCamel keys.
func object(value any) map[string]any {
	result := map[string]any{}
	v := reflect.Indirect(reflect.ValueOf(value))
	if !v.IsValid() {
		return result
	}
	t := v.Type()
	for i := 0; i < t.NumField(); i++ {
		field := t.Field(i)
		if !field.IsExported() || field.Type == reflect.TypeOf([]byte(nil)) {
			continue
		}
		result[lowerCamel(field.Name)] = v.Field(i).Interface()
	}
	return result
}

func jsonText(value any) string {
	data, err := json.Marshal(value)
	if err != nil {
		return "{}"
	}
	return string(data)
}

// decodeInto reads a JSON object into target (which holds the defaults): keys match field names regardless of case,
// unknown keys are an error.
func decodeInto(text string, target any) error {
	if strings.TrimSpace(text) == "" {
		return nil
	}
	decoder := json.NewDecoder(bytes.NewReader([]byte(text)))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(target); err != nil {
		return fmt.Errorf("aosgo: %T: %w", target, err)
	}
	return nil
}

// MARK: Log

type logSink struct{ fn C.aosgo_log_fn }

func (s logSink) Log(level int32, message string) {
	text := cText(message)
	C.aosgo_call_log(s.fn, C.int32_t(level), textPointer(text))
}

//export aosgo_set_log_handler
func aosgo_set_log_handler(fn C.aosgo_log_fn, minimumLevel C.int32_t) {
	if fn == nil {
		libsharing.SetLogHandler(nil, 0)
		return
	}
	libsharing.SetLogHandler(logSink{fn}, int32(minimumLevel))
}

// MARK: Handles

// registry hands out handles (> 0) for Go objects the caller refers to.
type registry[T any] struct {
	mu      sync.RWMutex
	next    atomic.Int64
	entries map[int64]T
}

func (r *registry[T]) add(value T) int64 {
	id := r.next.Add(1)
	r.mu.Lock()
	if r.entries == nil {
		r.entries = map[int64]T{}
	}
	r.entries[id] = value
	r.mu.Unlock()
	return id
}

func (r *registry[T]) get(id int64) (T, bool) {
	r.mu.RLock()
	value, found := r.entries[id]
	r.mu.RUnlock()
	return value, found
}

func (r *registry[T]) remove(id int64) (T, bool) {
	r.mu.Lock()
	value, found := r.entries[id]
	delete(r.entries, id)
	r.mu.Unlock()
	return value, found
}
