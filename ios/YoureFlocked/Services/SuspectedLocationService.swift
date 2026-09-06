import Foundation

actor SuspectedLocationService {
    static let shared = SuspectedLocationService()

    private enum Constants {
        static let csvURL = URL(string: "https://alprwatch.org/suspected-locations/deflock-latest.csv")!
        static let cacheFilename = "suspected-locations-cache.json"
        static let cacheTTL: TimeInterval = 7 * 24 * 60 * 60
        static let userAgent = "FLCKD/1.0 (iOS; +https://flckd.app)"
        static let defaultsLastDownloadKey = "suspectedLocationsLastDownload"
        static let defaultsCountKey = "suspectedLocationsCount"
    }

    private struct CachePayload: Codable {
        let fetchedAt: Date
        let locations: [SuspectedLocation]
    }

    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 180
        config.httpAdditionalHeaders = ["User-Agent": Constants.userAgent]
        self.session = URLSession(configuration: config)
    }

    func loadSuspectedLocations(forceRefresh: Bool = false) async throws -> [SuspectedLocation] {
        if !forceRefresh,
           let cached = try loadCacheIfFresh() {
            updateMetadata(count: cached.locations.count, date: cached.fetchedAt)
            return cached.locations
        }

        let (data, response) = try await session.data(from: Constants.csvURL)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw URLError(.badServerResponse)
        }

        let csvString = String(decoding: data, as: UTF8.self)
        let parsed = parseCSV(csvString)
        let payload = CachePayload(fetchedAt: Date(), locations: parsed)
        try saveCache(payload)
        updateMetadata(count: parsed.count, date: payload.fetchedAt)
        return parsed
    }

    func cachedMetadata() -> (count: Int, lastDownload: Date?) {
        let defaults = UserDefaults.standard
        let count = defaults.integer(forKey: Constants.defaultsCountKey)
        let date = defaults.object(forKey: Constants.defaultsLastDownloadKey) as? Date
        return (count, date)
    }

    private func cacheURL() throws -> URL {
        guard let cacheDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            throw URLError(.cannotCreateFile)
        }
        return cacheDirectory.appendingPathComponent(Constants.cacheFilename)
    }

    private func loadCacheIfFresh() throws -> CachePayload? {
        let url = try cacheURL()
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        let data = try Data(contentsOf: url)
        let payload = try JSONDecoder().decode(CachePayload.self, from: data)
        if Date().timeIntervalSince(payload.fetchedAt) > Constants.cacheTTL {
            return nil
        }
        return payload
    }

    private func saveCache(_ payload: CachePayload) throws {
        let data = try JSONEncoder().encode(payload)
        let url = try cacheURL()
        try data.write(to: url, options: [.atomic])
    }

    private func updateMetadata(count: Int, date: Date) {
        let defaults = UserDefaults.standard
        defaults.set(count, forKey: Constants.defaultsCountKey)
        defaults.set(date, forKey: Constants.defaultsLastDownloadKey)
    }

    private func parseCSV(_ text: String) -> [SuspectedLocation] {
        let rows = parseRows(text)
        guard let header = rows.first else { return [] }

        var indexByName: [String: Int] = [:]
        for (offset, name) in header.enumerated() {
            let key = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty {
                indexByName[key] = offset
            }
        }
        guard let locationIndex = indexByName["location"],
              let ticketIndex = indexByName["ticket_no"] else {
            return []
        }

        let workDoneIndex = indexByName["work done for"]
        let addressIndex = indexByName["address"]

        var results: [SuspectedLocation] = []
        results.reserveCapacity(max(0, rows.count - 1))

        for row in rows.dropFirst() {
            guard ticketIndex < row.count, locationIndex < row.count else { continue }

            let ticketNo = row[ticketIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            if ticketNo.isEmpty { continue }

            let locationJSON = row[locationIndex]
            guard let coordinate = parseGeoJSONLocation(locationJSON) else { continue }

            let workDoneFor = workDoneIndex.flatMap { idx in
                idx < row.count ? row[idx].nilIfEmpty : nil
            }
            let address = addressIndex.flatMap { idx in
                idx < row.count ? row[idx].nilIfEmpty : nil
            }

            results.append(SuspectedLocation(
                ticketNo: ticketNo,
                latitude: coordinate.latitude,
                longitude: coordinate.longitude,
                workDoneFor: workDoneFor,
                address: address
            ))
        }

        return results
    }

    private func parseGeoJSONLocation(_ value: String) -> (latitude: Double, longitude: Double)? {
        guard let data = value.data(using: .utf8),
              let jsonObject = try? JSONSerialization.jsonObject(with: data),
              let geoJSON = jsonObject as? [String: Any],
              let type = geoJSON["type"] as? String else {
            return nil
        }

        if type == "Point" {
            guard let coordinates = geoJSON["coordinates"] as? [Double], coordinates.count >= 2 else {
                return nil
            }
            return (latitude: coordinates[1], longitude: coordinates[0])
        }

        if type == "Polygon" {
            guard let coordinates = geoJSON["coordinates"] as? [[[Double]]] else {
                return nil
            }

            var totalLat: Double = 0
            var totalLon: Double = 0
            var count: Double = 0

            for ring in coordinates {
                for vertex in ring where vertex.count >= 2 {
                    totalLon += vertex[0]
                    totalLat += vertex[1]
                    count += 1
                }
            }

            guard count > 0 else { return nil }
            return (latitude: totalLat / count, longitude: totalLon / count)
        }

        return nil
    }

    private func parseRows(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false

        let characters = Array(text)
        var index = 0

        while index < characters.count {
            let character = characters[index]

            if character == "\"" {
                if inQuotes, index + 1 < characters.count, characters[index + 1] == "\"" {
                    field.append("\"")
                    index += 1
                } else {
                    inQuotes.toggle()
                }
            } else if character == ",", !inQuotes {
                row.append(field)
                field.removeAll(keepingCapacity: true)
            } else if (character == "\n" || character == "\r"), !inQuotes {
                if character == "\r", index + 1 < characters.count, characters[index + 1] == "\n" {
                    index += 1
                }
                row.append(field)
                if !row.isEmpty {
                    rows.append(row)
                }
                row = []
                field.removeAll(keepingCapacity: true)
            } else {
                field.append(character)
            }

            index += 1
        }

        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }

        return rows
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
