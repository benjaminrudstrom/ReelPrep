import Foundation

/// An exact rational number of seconds, as FCPXML writes time ("1001/30000s").
public struct RationalTime: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let num: Int64
    public let den: Int64

    public init(_ num: Int64, _ den: Int64 = 1) {
        precondition(den != 0, "RationalTime with zero denominator")
        let sign: Int64 = den < 0 ? -1 : 1
        let g = Swift.max(RationalTime.gcd(Swift.abs(num), Swift.abs(den)), 1)
        self.num = sign * num / g
        self.den = sign * den / g
    }

    public static let zero = RationalTime(0)

    /// Common frame durations.
    public static let fd23_976 = RationalTime(1001, 24000)
    public static let fd24 = RationalTime(1, 24)
    public static let fd25 = RationalTime(1, 25)
    public static let fd29_97 = RationalTime(1001, 30000)
    public static let fd30 = RationalTime(1, 30)
    public static let fd50 = RationalTime(1, 50)
    public static let fd59_94 = RationalTime(1001, 60000)
    public static let fd60 = RationalTime(1, 60)
    public static let fd119_88 = RationalTime(1001, 120000)
    public static let fd120 = RationalTime(1, 120)

    public var seconds: Double { Double(num) / Double(den) }

    /// FCPXML time string: "0s", "5s" or "1001/30000s".
    public var fcpxml: String {
        if num == 0 { return "0s" }
        if den == 1 { return "\(num)s" }
        return "\(num)/\(den)s"
    }

    public var description: String { fcpxml }

    static func gcd(_ a: Int64, _ b: Int64) -> Int64 {
        var (a, b) = (a, b)
        while b != 0 { (a, b) = (b, a % b) }
        return a
    }

    public static func + (l: RationalTime, r: RationalTime) -> RationalTime {
        let g = gcd(l.den, r.den)
        let lcm = l.den / g * r.den
        return RationalTime(l.num * (lcm / l.den) + r.num * (lcm / r.den), lcm)
    }

    public static func - (l: RationalTime, r: RationalTime) -> RationalTime { l + RationalTime(-r.num, r.den) }

    public static func * (l: RationalTime, r: RationalTime) -> RationalTime {
        let g1 = Swift.max(gcd(Swift.abs(l.num), r.den), 1)
        let g2 = Swift.max(gcd(Swift.abs(r.num), l.den), 1)
        return RationalTime((l.num / g1) * (r.num / g2), (l.den / g2) * (r.den / g1))
    }

    public static func / (l: RationalTime, r: RationalTime) -> RationalTime {
        precondition(r.num != 0, "division by zero time")
        return l * RationalTime(r.den, r.num)
    }

    public static func * (l: RationalTime, r: Int64) -> RationalTime { l * RationalTime(r) }
    public static func * (l: Int64, r: RationalTime) -> RationalTime { RationalTime(l) * r }

    public static func < (l: RationalTime, r: RationalTime) -> Bool {
        // Compare without overflow-prone cross multiplication where possible.
        (l - r).num < 0
    }

    /// Whole number of `unit`s in self, rounded down (self and unit positive).
    public func floorDiv(_ unit: RationalTime) -> Int64 {
        let q = self / unit
        return q.num >= 0 ? q.num / q.den : -((-q.num + q.den - 1) / q.den)
    }

    /// Nearest whole number of `unit`s in a time given in seconds.
    public static func roundFrames(_ seconds: Double, frameDuration: RationalTime) -> Int64 {
        Int64((seconds / frameDuration.seconds).rounded())
    }
}
