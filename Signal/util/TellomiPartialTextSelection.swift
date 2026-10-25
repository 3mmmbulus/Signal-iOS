//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

/// Pure selection logic for audit item 4.4: select part of a bubble's text
/// with drag handles and copy it. Not wired into the bubble yet.
/// All ranges are UTF-16 (NSRange) so they match UITextView / NSAttributedString.
enum TellomiPartialTextSelection {

    enum Handle { case start, end }

    /// Clamps `range` into `text` and widens it so it never splits a grapheme
    /// (emoji, flags, combining marks, CJK surrogate pairs).
    static func snapped(_ range: NSRange, in text: String) -> NSRange {
        let ns = text as NSString
        guard ns.length > 0 else { return NSRange(location: 0, length: 0) }
        let lo = max(0, min(range.location, ns.length))
        let hi = max(lo, min(range.location + max(0, range.length), ns.length))
        let start = lo == ns.length ? lo : ns.rangeOfComposedCharacterSequence(at: lo).location
        var end = hi
        if hi > 0 && hi < ns.length {
            let r = ns.rangeOfComposedCharacterSequence(at: hi)
            if r.location < hi { end = NSMaxRange(r) }
        }
        return NSRange(location: start, length: end - start)
    }

    /// Initial selection on long-press at `offset`: the word under the finger
    /// (for CJK, the single character, since there are no spaces).
    static func initialSelection(at offset: Int, in text: String) -> NSRange {
        let ns = text as NSString
        guard ns.length > 0 else { return NSRange(location: 0, length: 0) }
        let o = max(0, min(offset, ns.length - 1))
        let ch = ns.rangeOfComposedCharacterSequence(at: o)
        let scalar = ns.substring(with: ch).unicodeScalars.first!
        if isCJK(scalar) || !isWordScalar(scalar) { return ch }
        var s = ch.location, e = NSMaxRange(ch)
        while s > 0 {
            let p = ns.rangeOfComposedCharacterSequence(at: s - 1)
            guard let u = ns.substring(with: p).unicodeScalars.first, isWordScalar(u), !isCJK(u) else { break }
            s = p.location
        }
        while e < ns.length {
            let n = ns.rangeOfComposedCharacterSequence(at: e)
            guard let u = ns.substring(with: n).unicodeScalars.first, isWordScalar(u), !isCJK(u) else { break }
            e = NSMaxRange(n)
        }
        return NSRange(location: s, length: e - s)
    }

    /// Moves one handle to `offset`. If a handle is dragged past the other,
    /// the handles swap; the selection never becomes empty (min one grapheme).
    /// Returns the new range and which handle the finger now holds.
    static func drag(_ handle: Handle, to offset: Int, current: NSRange, in text: String) -> (range: NSRange, handle: Handle) {
        let ns = text as NSString
        guard ns.length > 0 else { return (NSRange(location: 0, length: 0), handle) }
        let o = max(0, min(offset, ns.length))
        let fixed = handle == .start ? NSMaxRange(current) : current.location
        var lo = min(o, fixed), hi = max(o, fixed)
        let held: Handle = (handle == .start) == (o <= fixed) ? handle : (handle == .start ? .end : .start)
        if lo == hi {
            if hi < ns.length { hi = NSMaxRange(ns.rangeOfComposedCharacterSequence(at: hi)) }
            else { lo = ns.rangeOfComposedCharacterSequence(at: lo - 1).location }
        }
        return (snapped(NSRange(location: lo, length: hi - lo), in: text), held)
    }

    /// Text to put on the pasteboard, or nil if nothing sensible is selected.
    static func textToCopy(_ range: NSRange, in text: String) -> String? {
        let r = snapped(range, in: text)
        guard r.length > 0 else { return nil }
        return (text as NSString).substring(with: r)
    }

    /// True when the whole message is selected; the menu then shows the
    /// existing "copy message" path instead of a partial copy.
    static func isWholeText(_ range: NSRange, in text: String) -> Bool {
        let r = snapped(range, in: text)
        return r.location == 0 && r.length == (text as NSString).length
    }

    private static func isWordScalar(_ u: Unicode.Scalar) -> Bool {
        CharacterSet.alphanumerics.contains(u) || u == "_" || u == "'"
    }

    private static func isCJK(_ u: Unicode.Scalar) -> Bool {
        switch u.value {
        case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xAC00...0xD7AF, 0xF900...0xFAFF, 0x20000...0x2FA1F: return true
        default: return false
        }
    }
}
