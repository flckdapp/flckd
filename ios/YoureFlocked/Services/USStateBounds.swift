import CoreLocation

/// Approximate bounding boxes for every region the tile server offers.
///
/// These drive preflight UX only ("is the user's state downloaded?",
/// "which state is the destination in?"). Routing correctness never depends
/// on them: the server cuts packs from real Geofabrik boundary polygons.
/// Boxes overlap at state borders, so containment picks the smallest
/// matching box, the most specific state.
struct USStateBounds: Sendable {
    let id: String   // matches the tile-server region id exactly
    let name: String
    let minLat: Double
    let minLon: Double
    let maxLat: Double
    let maxLon: Double

    var area: Double { (maxLat - minLat) * (maxLon - minLon) }

    func contains(_ coordinate: CLLocationCoordinate2D) -> Bool {
        if id == "alaska" {
            // Alaska crosses the antimeridian; a naive min/max box would
            // swallow most of the planet. Test mainland and Aleutians separately.
            return coordinate.latitude >= minLat && coordinate.latitude <= maxLat
                && (coordinate.longitude <= -129.9 || coordinate.longitude >= 170.0)
        }
        return coordinate.latitude >= minLat && coordinate.latitude <= maxLat
            && coordinate.longitude >= minLon && coordinate.longitude <= maxLon
    }

    /// The most specific region containing the coordinate, or nil when the
    /// coordinate is outside every region the server offers.
    static func region(containing coordinate: CLLocationCoordinate2D) -> USStateBounds? {
        all.filter { $0.contains(coordinate) }.min { $0.area < $1.area }
    }

    static let all: [USStateBounds] = [
        USStateBounds(id: "alabama", name: "Alabama", minLat: 30.223334, minLon: -88.473227, maxLat: 35.008028, maxLon: -84.88908),
        USStateBounds(id: "alaska", name: "Alaska", minLat: 51.214183, minLon: -179.148909, maxLat: 71.365162, maxLon: 179.77847),
        USStateBounds(id: "arizona", name: "Arizona", minLat: 31.332177, minLon: -114.81651, maxLat: 37.00426, maxLon: -109.045223),
        USStateBounds(id: "arkansas", name: "Arkansas", minLat: 33.004106, minLon: -94.617919, maxLat: 36.4996, maxLon: -89.644395),
        USStateBounds(id: "california", name: "California", minLat: 32.534156, minLon: -124.409591, maxLat: 42.009518, maxLon: -114.131211),
        USStateBounds(id: "colorado", name: "Colorado", minLat: 36.992426, minLon: -109.060253, maxLat: 41.003444, maxLon: -102.041524),
        USStateBounds(id: "connecticut", name: "Connecticut", minLat: 40.980144, minLon: -73.727775, maxLat: 42.050587, maxLon: -71.786994),
        USStateBounds(id: "delaware", name: "Delaware", minLat: 38.451013, minLon: -75.788658, maxLat: 39.839007, maxLon: -75.048939),
        USStateBounds(id: "district-of-columbia", name: "District of Columbia", minLat: 38.791645, minLon: -77.119759, maxLat: 38.99511, maxLon: -76.909395),
        USStateBounds(id: "florida", name: "Florida", minLat: 24.523096, minLon: -87.634938, maxLat: 31.000888, maxLon: -80.031362),
        USStateBounds(id: "georgia", name: "Georgia", minLat: 30.357851, minLon: -85.605165, maxLat: 35.000659, maxLon: -80.839729),
        USStateBounds(id: "hawaii", name: "Hawaii", minLat: 18.910361, minLon: -178.334698, maxLat: 28.402123, maxLon: -154.806773),
        USStateBounds(id: "idaho", name: "Idaho", minLat: 41.988057, minLon: -117.243027, maxLat: 49.001146, maxLon: -111.043564),
        USStateBounds(id: "illinois", name: "Illinois", minLat: 36.970298, minLon: -91.513079, maxLat: 42.508481, maxLon: -87.494756),
        USStateBounds(id: "indiana", name: "Indiana", minLat: 37.771742, minLon: -88.09776, maxLat: 41.760592, maxLon: -84.784579),
        USStateBounds(id: "iowa", name: "Iowa", minLat: 40.375501, minLon: -96.639704, maxLat: 43.501196, maxLon: -90.140061),
        USStateBounds(id: "kansas", name: "Kansas", minLat: 36.993016, minLon: -102.051744, maxLat: 40.003162, maxLon: -94.588413),
        USStateBounds(id: "kentucky", name: "Kentucky", minLat: 36.497129, minLon: -89.571509, maxLat: 39.147458, maxLon: -81.964971),
        USStateBounds(id: "louisiana", name: "Louisiana", minLat: 28.928609, minLon: -94.043147, maxLat: 33.019457, maxLon: -88.817017),
        USStateBounds(id: "maine", name: "Maine", minLat: 42.977764, minLon: -71.083924, maxLat: 47.459686, maxLon: -66.949895),
        USStateBounds(id: "maryland", name: "Maryland", minLat: 37.911717, minLon: -79.487651, maxLat: 39.723043, maxLon: -75.048939),
        USStateBounds(id: "massachusetts", name: "Massachusetts", minLat: 41.237964, minLon: -73.508142, maxLat: 42.886589, maxLon: -69.928393),
        USStateBounds(id: "michigan", name: "Michigan", minLat: 41.696118, minLon: -90.418136, maxLat: 48.2388, maxLon: -82.413474),
        USStateBounds(id: "minnesota", name: "Minnesota", minLat: 43.499356, minLon: -97.239209, maxLat: 49.384358, maxLon: -89.491739),
        USStateBounds(id: "mississippi", name: "Mississippi", minLat: 30.173943, minLon: -91.655009, maxLat: 34.996052, maxLon: -88.097888),
        USStateBounds(id: "missouri", name: "Missouri", minLat: 35.995683, minLon: -95.774704, maxLat: 40.61364, maxLon: -89.098843),
        USStateBounds(id: "montana", name: "Montana", minLat: 44.358221, minLon: -116.050003, maxLat: 49.00139, maxLon: -104.039138),
        USStateBounds(id: "nebraska", name: "Nebraska", minLat: 39.999998, minLon: -104.053514, maxLat: 43.001708, maxLon: -95.30829),
        USStateBounds(id: "nevada", name: "Nevada", minLat: 35.001857, minLon: -120.005746, maxLat: 42.002207, maxLon: -114.039648),
        USStateBounds(id: "new-hampshire", name: "New Hampshire", minLat: 42.69699, minLon: -72.557247, maxLat: 45.305476, maxLon: -70.610621),
        USStateBounds(id: "new-jersey", name: "New Jersey", minLat: 38.928519, minLon: -75.559614, maxLat: 41.357423, maxLon: -73.893979),
        USStateBounds(id: "new-mexico", name: "New Mexico", minLat: 31.332301, minLon: -109.050173, maxLat: 37.000232, maxLon: -103.001964),
        USStateBounds(id: "new-york", name: "New York", minLat: 40.496103, minLon: -79.762152, maxLat: 45.01585, maxLon: -71.856214),
        USStateBounds(id: "north-carolina", name: "North Carolina", minLat: 33.842316, minLon: -84.321869, maxLat: 36.588117, maxLon: -75.460621),
        USStateBounds(id: "north-dakota", name: "North Dakota", minLat: 45.935054, minLon: -104.0489, maxLat: 49.000574, maxLon: -96.554507),
        USStateBounds(id: "ohio", name: "Ohio", minLat: 38.403202, minLon: -84.820159, maxLat: 41.977523, maxLon: -80.518693),
        USStateBounds(id: "oklahoma", name: "Oklahoma", minLat: 33.615833, minLon: -103.002565, maxLat: 37.002206, maxLon: -94.430662),
        USStateBounds(id: "oregon", name: "Oregon", minLat: 41.991794, minLon: -124.566244, maxLat: 46.292035, maxLon: -116.463504),
        USStateBounds(id: "pennsylvania", name: "Pennsylvania", minLat: 39.7198, minLon: -80.519891, maxLat: 42.26986, maxLon: -74.689516),
        USStateBounds(id: "puerto-rico", name: "Puerto Rico", minLat: 17.88328, minLon: -67.945404, maxLat: 18.515683, maxLon: -65.220703),
        USStateBounds(id: "rhode-island", name: "Rhode Island", minLat: 41.146339, minLon: -71.862772, maxLat: 42.018798, maxLon: -71.12057),
        USStateBounds(id: "south-carolina", name: "South Carolina", minLat: 32.0346, minLon: -83.35391, maxLat: 35.215402, maxLon: -78.54203),
        USStateBounds(id: "south-dakota", name: "South Dakota", minLat: 42.479635, minLon: -104.057698, maxLat: 45.94545, maxLon: -96.436589),
        USStateBounds(id: "tennessee", name: "Tennessee", minLat: 34.982972, minLon: -90.310298, maxLat: 36.678118, maxLon: -81.6469),
        USStateBounds(id: "texas", name: "Texas", minLat: 25.837377, minLon: -106.645646, maxLat: 36.500704, maxLon: -93.508292),
        USStateBounds(id: "us-virgin-islands", name: "U.S. Virgin Islands", minLat: 17.673976, minLon: -65.085452, maxLat: 18.412655, maxLon: -64.564907),
        USStateBounds(id: "utah", name: "Utah", minLat: 36.997968, minLon: -114.052962, maxLat: 42.001567, maxLon: -109.041058),
        USStateBounds(id: "vermont", name: "Vermont", minLat: 42.726853, minLon: -73.43774, maxLat: 45.016659, maxLon: -71.464555),
        USStateBounds(id: "virginia", name: "Virginia", minLat: 36.540738, minLon: -83.675395, maxLat: 39.466012, maxLon: -75.242266),
        USStateBounds(id: "washington", name: "Washington", minLat: 45.543541, minLon: -124.763068, maxLat: 49.002494, maxLon: -116.915989),
        USStateBounds(id: "west-virginia", name: "West Virginia", minLat: 37.201483, minLon: -82.644739, maxLat: 40.638801, maxLon: -77.719519),
        USStateBounds(id: "wisconsin", name: "Wisconsin", minLat: 42.491983, minLon: -92.888114, maxLat: 47.080621, maxLon: -86.805415),
        USStateBounds(id: "wyoming", name: "Wyoming", minLat: 40.994746, minLon: -111.056888, maxLat: 45.005904, maxLon: -104.05216),
    ]
}
