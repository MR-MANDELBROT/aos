import Foundation

// What a terminal session on the Mac keeps of its output (the iPhone's terminal, Docs/COMPANION.md "Terminal
// sessions"): the last output in a ring with absolute byte offsets, so a phone that comes back gets exactly what it
// missed, and the modes a program switched on, so a phone that has nothing can be put into the same state before it
// gets the last part of the output. Pure, tested in TermStreamTests.

/// The terminal state a fresh terminal needs to continue a program's output from the middle of the stream: the
/// modes programs switch with escape sequences (alternate screen, cursor keys, keypad, mouse, bracketed paste, the
/// keyboard protocol, the cursor), and whether the stream is in the middle of a sequence or a character. Also the
/// window title a program set (OSC 0 or 2).
public struct TermModes: Equatable, Sendable {
    public var applicationCursor = false
    public var autowrap = true
    public var cursorVisible = true
    public var alternateScreen = false
    public var keypadApplication = false
    public var bracketedPaste = false
    public var focusEvents = false
    public var alternateScroll = false
    /// The mouse tracking mode that is on (9, 1000, 1001, 1002, 1003), if any.
    public var mouseTracking: Int?
    /// The mouse encoding that is on (1005, 1006, 1015, 1016), if any.
    public var mouseEncoding: Int?
    /// DECSCUSR (`CSI Ps SP q`); nil is the terminal's default.
    public var cursorStyle: Int?
    /// The kitty keyboard protocol's flags, a stack per screen (the top is in effect).
    public var keyboardMain: [Int] = []
    public var keyboardAlternate: [Int] = []
    /// What a program called the window (OSC 0 or 2), at most 256 characters.
    public var title: String?

    enum State: UInt8, Sendable { case ground, escape, escapeIntermediate, csi, osc, oscEscape, string, stringEscape }

    private var state: State = .ground
    private var utf8Remaining = 0
    /// Parameter and intermediate bytes of the CSI sequence being read (at most 64).
    private var params: [UInt8] = []
    /// The OSC string being read (at most 1024 bytes are kept).
    private var osc: [UInt8] = []

    public init() {}

    /// Between two sequences and two characters: a terminal can start reading here.
    public var isSafePoint: Bool { state == .ground && utf8Remaining == 0 }

    /// The kitty keyboard flags in effect on the active screen.
    public var keyboardFlags: Int { (alternateScreen ? keyboardAlternate : keyboardMain).last ?? 0 }

    // MARK: Reading

    public mutating func feed<S: Sequence>(_ bytes: S) where S.Element == UInt8 {
        for byte in bytes { feed(byte) }
    }

    public mutating func feed(_ byte: UInt8) {
        switch state {
        case .ground:
            ground(byte)
        case .escape:
            escape(byte)
        case .escapeIntermediate:
            if byte == 0x1b { state = .escape }
            else if byte == 0x18 || byte == 0x1a { state = .ground }
            else if (0x30...0x7e).contains(byte) { state = .ground }
        case .csi:
            if byte == 0x1b { state = .escape; params.removeAll(keepingCapacity: true) }
            else if byte == 0x18 || byte == 0x1a { state = .ground; params.removeAll(keepingCapacity: true) }
            else if (0x40...0x7e).contains(byte) {
                dispatchCSI(final: byte)
                params.removeAll(keepingCapacity: true)
                state = .ground
            } else if (0x20...0x3f).contains(byte) {
                if params.count < 64 { params.append(byte) }
            }
            // Other C0 controls inside a CSI sequence act on their own and don't end it.
        case .osc:
            if byte == 0x07 { dispatchOSC(); state = .ground }
            else if byte == 0x1b { state = .oscEscape }
            else if byte == 0x18 || byte == 0x1a { osc.removeAll(keepingCapacity: true); state = .ground }
            else if osc.count < 1024 { osc.append(byte) }
        case .oscEscape:
            if byte == 0x5c {
                dispatchOSC()
                state = .ground
            } else {
                // An escape that isn't the string terminator ends the string and starts a new sequence.
                osc.removeAll(keepingCapacity: true)
                state = .escape
                escape(byte)
            }
        case .string:
            if byte == 0x1b { state = .stringEscape }
            else if byte == 0x18 || byte == 0x1a { state = .ground }
        case .stringEscape:
            if byte == 0x5c { state = .ground } else { state = .escape; escape(byte) }
        }
    }

    private mutating func ground(_ byte: UInt8) {
        switch byte {
        case 0x1b:
            utf8Remaining = 0
            state = .escape
        case 0x00...0x7f:
            utf8Remaining = 0
        case 0x80...0xbf:
            if utf8Remaining > 0 { utf8Remaining -= 1 }
        case 0xc2...0xdf:
            utf8Remaining = 1
        case 0xe0...0xef:
            utf8Remaining = 2
        case 0xf0...0xf4:
            utf8Remaining = 3
        default:
            utf8Remaining = 0
        }
    }

    private mutating func escape(_ byte: UInt8) {
        switch byte {
        case 0x5b: // [
            params.removeAll(keepingCapacity: true)
            state = .csi
        case 0x5d: // ]
            osc.removeAll(keepingCapacity: true)
            state = .osc
        case 0x50, 0x58, 0x5e, 0x5f: // P X ^ _: DCS, SOS, PM, APC
            state = .string
        case 0x20...0x2f:
            state = .escapeIntermediate
        case 0x1b:
            state = .escape
        case 0x18, 0x1a:
            state = .ground
        case 0x63: // c: RIS, the whole terminal back to its start
            let title = self.title
            self = TermModes()
            self.title = title
        case 0x3d: // =
            keypadApplication = true
            state = .ground
        case 0x3e: // >
            keypadApplication = false
            state = .ground
        default:
            state = byte < 0x20 ? .escape : .ground
        }
    }

    private mutating func dispatchCSI(final: UInt8) {
        let marker = params.first.flatMap { (0x3c...0x3f).contains($0) ? $0 : nil }
        let intermediates = params.filter { (0x20...0x2f).contains($0) }
        let body = params.drop { (0x3c...0x3f).contains($0) }.filter { !(0x20...0x2f).contains($0) }
        let numbers = Self.numbers(body)
        switch (marker, final) {
        case (0x3f, 0x68), (0x3f, 0x6c): // ? h / ? l
            for mode in numbers { setPrivate(mode, final == 0x68) }
        case (0x3e, 0x75): // > u: push keyboard flags
            pushKeyboard(numbers.first ?? 0)
        case (0x3c, 0x75): // < u: pop
            popKeyboard(max(numbers.first ?? 1, 1))
        case (0x3d, 0x75): // = u: set
            setKeyboard(numbers.first ?? 0, mode: numbers.count > 1 ? numbers[1] : 1)
        case (nil, 0x71) where intermediates == [0x20]: // SP q: cursor style
            let style = numbers.first ?? 0
            cursorStyle = style == 0 ? nil : style
        case (nil, 0x70) where intermediates == [0x21]: // ! p: soft reset
            applicationCursor = false
            keypadApplication = false
            cursorVisible = true
            autowrap = true
        default:
            break
        }
    }

    private static func numbers(_ bytes: [UInt8]) -> [Int] {
        var result: [Int] = []
        var current: Int?
        for byte in bytes {
            if (0x30...0x39).contains(byte) {
                current = min((current ?? 0) * 10 + Int(byte - 0x30), 99_999)
            } else if byte == 0x3b || byte == 0x3a {
                result.append(current ?? 0)
                current = nil
            }
        }
        if let current { result.append(current) }
        return result
    }

    private mutating func setPrivate(_ mode: Int, _ on: Bool) {
        switch mode {
        case 1: applicationCursor = on
        case 7: autowrap = on
        case 25: cursorVisible = on
        case 47, 1047, 1049: alternateScreen = on
        case 1004: focusEvents = on
        case 1007: alternateScroll = on
        case 2004: bracketedPaste = on
        case 9, 1000, 1001, 1002, 1003:
            if on { mouseTracking = mode } else if mouseTracking == mode { mouseTracking = nil }
        case 1005, 1006, 1015, 1016:
            if on { mouseEncoding = mode } else if mouseEncoding == mode { mouseEncoding = nil }
        default:
            break
        }
    }

    private mutating func pushKeyboard(_ flags: Int) {
        if alternateScreen {
            keyboardAlternate.append(flags)
            if keyboardAlternate.count > 16 { keyboardAlternate.removeFirst() }
        } else {
            keyboardMain.append(flags)
            if keyboardMain.count > 16 { keyboardMain.removeFirst() }
        }
    }

    private mutating func popKeyboard(_ count: Int) {
        if alternateScreen { keyboardAlternate.removeLast(min(count, keyboardAlternate.count)) }
        else { keyboardMain.removeLast(min(count, keyboardMain.count)) }
    }

    private mutating func setKeyboard(_ flags: Int, mode: Int) {
        let current = keyboardFlags
        let value: Int
        switch mode {
        case 2: value = current | flags
        case 3: value = current & ~flags
        default: value = flags
        }
        if alternateScreen {
            if keyboardAlternate.isEmpty { keyboardAlternate.append(value) } else { keyboardAlternate[keyboardAlternate.count - 1] = value }
        } else {
            if keyboardMain.isEmpty { keyboardMain.append(value) } else { keyboardMain[keyboardMain.count - 1] = value }
        }
    }

    private mutating func dispatchOSC() {
        defer { osc.removeAll(keepingCapacity: true) }
        guard let separator = osc.firstIndex(of: 0x3b) else { return }
        let code = String(decoding: osc[..<separator], as: UTF8.self)
        guard code == "0" || code == "2" else { return }
        let text = String(decoding: osc[(separator + 1)...], as: UTF8.self)
            .filter { !$0.isNewline && $0.unicodeScalars.allSatisfy { $0.value >= 0x20 } }
        title = text.isEmpty ? nil : String(text.prefix(256))
    }

    // MARK: Writing

    /// Escape sequences that put a terminal fresh from a reset into these modes (the alternate screen first: the
    /// keyboard flags belong to the screen).
    public var prefix: [UInt8] {
        var out = ""
        func csi(_ s: String) { out += "\u{1b}[" + s }
        if alternateScreen { csi("?1049h") }
        if applicationCursor { csi("?1h") }
        if !autowrap { csi("?7l") }
        if keypadApplication { out += "\u{1b}=" }
        if bracketedPaste { csi("?2004h") }
        if focusEvents { csi("?1004h") }
        if alternateScroll { csi("?1007h") }
        if let mouseTracking { csi("?\(mouseTracking)h") }
        if let mouseEncoding { csi("?\(mouseEncoding)h") }
        if let cursorStyle { csi("\(cursorStyle) q") }
        if keyboardFlags != 0 { csi(">\(keyboardFlags)u") }
        if !cursorVisible { csi("?25l") }
        return Array(out.utf8)
    }
}

/// The last output of a terminal session, with absolute offsets: byte `start` is the oldest one kept, `end` the
/// offset after the newest. `modesAtStart` is the terminal state at `start` (fed with everything dropped from the
/// ring), `modesAtEnd` the state now.
public struct TermRing: Sendable {
    public let capacity: Int
    private var storage: [UInt8]
    /// Index in `storage` of the byte at `start`.
    private var head = 0
    public private(set) var count = 0
    public private(set) var start: UInt64 = 0
    public private(set) var modesAtStart = TermModes()
    public private(set) var modesAtEnd = TermModes()

    public init(capacity: Int = 1 << 20) {
        self.capacity = max(capacity, 16)
        storage = [UInt8](repeating: 0, count: self.capacity)
    }

    public var end: UInt64 { start + UInt64(count) }

    public mutating func append(_ bytes: [UInt8]) {
        bytes.withUnsafeBufferPointer { append($0) }
    }

    public mutating func append(_ bytes: UnsafeBufferPointer<UInt8>) {
        guard !bytes.isEmpty else { return }
        modesAtEnd.feed(bytes)
        var input = bytes[...]
        let overflow = count + input.count - capacity
        if overflow > 0 {
            // The oldest bytes go (the terminal state at the new start follows them), and of a chunk bigger than the
            // whole ring only its end is kept.
            drop(min(overflow, count))
            if input.count > capacity {
                let skipped = input.count - capacity
                modesAtStart.feed(input.prefix(skipped))
                start += UInt64(skipped)
                input = input.dropFirst(skipped)
            }
        }
        var tail = (head + count) % capacity
        for byte in input {
            storage[tail] = byte
            tail += 1
            if tail == capacity { tail = 0 }
        }
        count += input.count
    }

    private mutating func drop(_ n: Int) {
        guard n > 0 else { return }
        var index = head
        for _ in 0..<n {
            modesAtStart.feed(storage[index])
            index += 1
            if index == capacity { index = 0 }
        }
        head = index
        count -= n
        start += UInt64(n)
    }

    /// Up to `limit` bytes from `offset` (clamped to what the ring has).
    public func bytes(from offset: UInt64, limit: Int = .max) -> [UInt8] {
        guard offset < end else { return [] }
        let from = max(offset, start)
        let n = Int(min(UInt64(limit), end - from))
        var result = [UInt8]()
        result.reserveCapacity(n)
        var index = (head + Int(from - start)) % capacity
        for _ in 0..<n {
            result.append(storage[index])
            index += 1
            if index == capacity { index = 0 }
        }
        return result
    }

    /// What a client gets when it attaches. A client that has everything up to `have` (inside the ring) gets the
    /// rest exactly. Any other (nothing yet, or too much missed) gets a fresh start: the last `budget` bytes or so,
    /// from a point between two sequences, preferably right after a line break, with `prefix` to put its terminal
    /// into the modes in effect there.
    public func replay(have: UInt64?, budget: Int = 256 * 1024) -> TermReplay {
        if let have, have >= start, have <= end {
            return TermReplay(from: have, reset: false, prefix: [])
        }
        var modes = modesAtStart
        let target = end - UInt64(min(count, max(budget, 0)))
        var offset = start
        var index = head
        func step() {
            modes.feed(storage[index])
            index += 1
            if index == capacity { index = 0 }
            offset += 1
        }
        while offset < target { step() }
        while offset < end, !modes.isSafePoint { step() }
        // A line break within the next 4 KB is a nicer place to start.
        var probe = modes, probeOffset = offset, probeIndex = index
        while probeOffset < end, probeOffset - offset < 4096 {
            let byte = storage[probeIndex]
            probe.feed(byte)
            probeIndex += 1
            if probeIndex == capacity { probeIndex = 0 }
            probeOffset += 1
            if byte == 0x0a, probe.isSafePoint {
                modes = probe
                offset = probeOffset
                break
            }
        }
        return TermReplay(from: offset, reset: true, prefix: modes.prefix)
    }
}

/// Where a client's output starts, and how.
public struct TermReplay: Equatable, Sendable {
    /// The offset of the first byte the client gets.
    public var from: UInt64
    /// The client resets its terminal first (it has nothing, or missed more than the ring keeps).
    public var reset: Bool
    /// After a reset: escape sequences for the modes in effect at `from` (not part of the stream's offsets).
    public var prefix: [UInt8]
}
