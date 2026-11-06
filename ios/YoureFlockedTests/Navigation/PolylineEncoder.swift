import CoreLocation
import Foundation

/// Encodes coordinates the way Valhalla's OSRM serializer does, so a test can
/// build a response from readable numbers instead of a pasted string.
///
/// Precision 6 matches `shape_format: polyline6`, which the guidance request
/// asks for and `FlckdRouteProvider` decodes with.
enum PolylineEncoder {

    static func encode(_ coordinates: [CLLocationCoordinate2D], precision: Double = 1e6) -> String {
        var output = ""
        var previousLatitude = 0
        var previousLongitude = 0
        for coordinate in coordinates {
            let latitude = Int((coordinate.latitude * precision).rounded())
            let longitude = Int((coordinate.longitude * precision).rounded())
            output += encode(value: latitude - previousLatitude)
            output += encode(value: longitude - previousLongitude)
            previousLatitude = latitude
            previousLongitude = longitude
        }
        return output
    }

    /// Zig-zag then base-64-ish chunking: each 5-bit group is offset by 63 into
    /// printable ASCII, with the 0x20 bit marking "another group follows".
    private static func encode(value: Int) -> String {
        var remaining = value < 0 ? ~(value << 1) : (value << 1)
        var encoded = ""
        while remaining >= 0x20 {
            encoded.append(Character(UnicodeScalar(UInt8(0x20 | (remaining & 0x1F)) + 63)))
            remaining >>= 5
        }
        encoded.append(Character(UnicodeScalar(UInt8(remaining) + 63)))
        return encoded
    }
}
