import Foundation

/// Text on the Palm is Windows-1252, one byte per character.
///
/// Decoding is lossless: the five bytes Windows-1252 leaves undefined
/// (0x81, 0x8D, 0x8F, 0x90, 0x9D) become the control characters of the same
/// value, so every byte comes back unchanged when encoded again. Encoding
/// replaces what the Palm cannot show (emoji, most non-Latin scripts) with
/// "?".
public enum PalmText {
    /// 0x80...0x9F; everything else is Latin-1 (byte value = code point)
    private static let high: [UInt32] = [
        0x20AC, 0x0081, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021,
        0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0x008D, 0x017D, 0x008F,
        0x0090, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014,
        0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0x009D, 0x017E, 0x0178,
    ]

    private static let highReverse: [UInt32: UInt8] = {
        var map = [UInt32: UInt8]()
        for (i, code) in high.enumerated() { map[code] = UInt8(0x80 + i) }
        return map
    }()

    public static func decode<Bytes: Sequence>(_ bytes: Bytes) -> String where Bytes.Element == UInt8 {
        var scalars = String.UnicodeScalarView()
        for byte in bytes {
            if byte >= 0x80 && byte < 0xA0 {
                // every entry of the table is a valid scalar
                scalars.append(Unicode.Scalar(high[Int(byte - 0x80)])!)
            } else {
                scalars.append(Unicode.Scalar(byte))
            }
        }
        return String(scalars)
    }

    /// The bytes for the Palm, without a terminating NUL. A NUL in the text
    /// would end it early on the Palm and becomes "?" as well.
    public static func encode(_ text: String) -> [UInt8] {
        // "é" as "e" plus a combining accent is one character in Windows-1252
        let composed = text.precomposedStringWithCanonicalMapping
        var bytes = [UInt8]()
        bytes.reserveCapacity(composed.unicodeScalars.count)
        for scalar in composed.unicodeScalars {
            let value = scalar.value
            if value == 0 {
                bytes.append(0x3F)
            } else if value < 0x80 || (value >= 0xA0 && value <= 0xFF) {
                bytes.append(UInt8(value))
            } else if let byte = highReverse[value] {
                bytes.append(byte)
            } else {
                bytes.append(0x3F)  // "?"
            }
        }
        return bytes
    }

    /// The text as it comes back from the Palm. Comparing this, not the
    /// original, tells whether the Palm changed a text or only could not
    /// hold all of it.
    public static func representable(_ text: String) -> String {
        decode(encode(text))
    }
}
