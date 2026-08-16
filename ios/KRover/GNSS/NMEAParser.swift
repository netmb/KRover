import CoreLocation
import Foundation

final class NMEAParser {
    private var buffer = Data()
    private var nextSampleID: UInt64 = 1
    private var latest = GNSSPosition(
        coordinate: CLLocationCoordinate2D(latitude: 0, longitude: 0), altitude: nil,
        horizontalSigma: nil, verticalSigma: nil, fixQuality: .none,
        satellites: 0, hdop: nil, timestamp: .distantPast
    )

    var onPosition: ((GNSSPosition) -> Void)?
    var onGGA: ((String) -> Void)?

    func reset() {
        buffer.removeAll(keepingCapacity: true)
        nextSampleID = 1
    }

    func append(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer.prefix(upTo: newline)
            buffer.removeSubrange(...newline)
            guard let line = String(data: lineData, encoding: .ascii)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !line.isEmpty else { continue }
            parse(line)
        }
        if buffer.count > 8_192 { buffer.removeAll(keepingCapacity: true) }
    }

    private func parse(_ line: String) {
        guard Self.hasValidChecksum(line) else { return }
        let body = line.dropFirst().split(separator: "*", maxSplits: 1)[0]
        let fields = body.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard let sentence = fields.first else { return }

        if sentence.hasSuffix("GGA"), fields.count >= 10 {
            guard let coordinate = Self.coordinate(
                latitude: fields[2], latitudeHemisphere: fields[3],
                longitude: fields[4], longitudeHemisphere: fields[5]
            ) else { return }
            latest.coordinate = coordinate
            latest.fixQuality = FixQuality(ggaCode: Int(fields[6]) ?? 0)
            latest.satellites = Int(fields[7]) ?? 0
            latest.hdop = Double(fields[8])
            latest.altitude = Double(fields[9])
            latest.timestamp = Date()
            latest.sampleID = nextSampleID
            nextSampleID &+= 1
            onGGA?(line)
            onPosition?(latest)
        } else if sentence.hasSuffix("GST"), fields.count >= 9 {
            let latitudeSigma = Double(fields[6])
            let longitudeSigma = Double(fields[7])
            if let lat = latitudeSigma, let lon = longitudeSigma {
                latest.horizontalSigma = hypot(lat, lon)
            }
            latest.verticalSigma = Double(fields[8])
            onPosition?(latest)
        }
    }

    static func hasValidChecksum(_ line: String) -> Bool {
        guard line.first == "$", let star = line.firstIndex(of: "*") else { return false }
        let checksumText = line[line.index(after: star)...].prefix(2)
        guard checksumText.count == 2, let expected = UInt8(checksumText, radix: 16) else { return false }
        var actual: UInt8 = 0
        for byte in line[line.index(after: line.startIndex)..<star].utf8 { actual ^= byte }
        return actual == expected
    }

    static func coordinate(
        latitude: String, latitudeHemisphere: String,
        longitude: String, longitudeHemisphere: String
    ) -> CLLocationCoordinate2D? {
        guard let rawLat = Double(latitude), let rawLon = Double(longitude) else { return nil }
        var lat = floor(rawLat / 100) + rawLat.truncatingRemainder(dividingBy: 100) / 60
        var lon = floor(rawLon / 100) + rawLon.truncatingRemainder(dividingBy: 100) / 60
        if latitudeHemisphere == "S" { lat = -lat }
        if longitudeHemisphere == "W" { lon = -lon }
        guard (-90...90).contains(lat), (-180...180).contains(lon) else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }
}
