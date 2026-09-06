import Foundation
import CoreLocation

struct SuspectedLocation: Identifiable, Codable, Hashable {
    let ticketNo: String
    let latitude: Double
    let longitude: Double
    let workDoneFor: String?
    let address: String?

    var id: String { ticketNo }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}
