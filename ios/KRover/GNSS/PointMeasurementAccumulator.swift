import CoreLocation
import Foundation

struct PointMeasurementAccumulator {
    struct Configuration {
        let targetDuration: TimeInterval
        let minimumSamples: Int
        let poleLengthMeters: Double
        let minimumSampleSpacing: TimeInterval
        let requiresAltitude: Bool

        init(
            targetDuration: TimeInterval,
            minimumSamples: Int,
            poleLengthMeters: Double,
            minimumSampleSpacing: TimeInterval = 0,
            requiresAltitude: Bool = false
        ) {
            self.targetDuration = targetDuration
            self.minimumSamples = minimumSamples
            self.poleLengthMeters = poleLengthMeters
            self.minimumSampleSpacing = minimumSampleSpacing
            self.requiresAltitude = requiresAltitude
        }

        static func standard(
            for source: PointMeasurementSource,
            poleLengthMeters: Double
        ) -> Configuration {
            switch source {
            case .roverRTK:
                return Configuration(
                    targetDuration: 0.35,
                    minimumSamples: 5,
                    poleLengthMeters: poleLengthMeters,
                    minimumSampleSpacing: 0.075
                )
            case .iphoneTest:
                return Configuration(
                    targetDuration: 3.0,
                    minimumSamples: 3,
                    poleLengthMeters: 0
                )
            }
        }

        static func elevation(
            for source: PointMeasurementSource,
            poleLengthMeters: Double
        ) -> Configuration {
            switch source {
            case .roverRTK:
                return Configuration(
                    targetDuration: 2.0,
                    minimumSamples: 15,
                    poleLengthMeters: poleLengthMeters,
                    minimumSampleSpacing: 0.075,
                    requiresAltitude: true
                )
            case .iphoneTest:
                return Configuration(
                    targetDuration: 5.0,
                    minimumSamples: 5,
                    poleLengthMeters: 0,
                    requiresAltitude: true
                )
            }
        }
    }

    private struct Sample {
        let id: UInt64
        let coordinate: UTMCoordinate
        let timestamp: Date
        let tiltDegrees: Double
        let combinedUncertainty: Double
        let altitudeMSL: Double?
        let verticalUncertainty: Double
    }

    let source: PointMeasurementSource
    let configuration: Configuration
    private var samples: [Sample] = []

    init(source: PointMeasurementSource, configuration: Configuration) {
        self.source = source
        self.configuration = configuration
    }

    var sampleCount: Int { samples.count }

    var duration: TimeInterval {
        guard let first = samples.first?.timestamp,
              let last = samples.last?.timestamp else { return 0 }
        return max(0, last.timeIntervalSince(first))
    }

    var progress: Double {
        let durationProgress = duration / configuration.targetDuration
        let sampleProgress = Double(sampleCount) / Double(configuration.minimumSamples)
        return min(1, max(0, min(durationProgress, sampleProgress)))
    }

    mutating func add(
        position: GNSSPosition,
        tiltDegrees: Double
    ) -> PointMeasurementResult? {
        let projected = UTM32Projection.project(position.coordinate)
        let defaultSigma = source == .roverRTK ? 0.02 : 10.0
        let gnssSigma = max(0.005, position.horizontalSigma ?? defaultSigma)
        let defaultVerticalSigma = source == .roverRTK ? 0.04 : 10.0
        let tiltOffset = configuration.poleLengthMeters *
            sin(abs(tiltDegrees) * .pi / 180)
        let sample = Sample(
            id: position.sampleID,
            coordinate: projected,
            timestamp: position.timestamp,
            tiltDegrees: abs(tiltDegrees),
            combinedUncertainty: hypot(gnssSigma, tiltOffset),
            altitudeMSL: position.altitude,
            verticalUncertainty: max(0.01, position.verticalSigma ?? defaultVerticalSigma)
        )

        if let index = samples.firstIndex(where: { $0.id == sample.id }) {
            samples[index] = sample
        } else {
            if let previous = samples.last,
               sample.timestamp.timeIntervalSince(previous.timestamp) < configuration.minimumSampleSpacing {
                return nil
            }
            samples.append(sample)
            samples.sort { $0.timestamp < $1.timestamp }
        }

        guard sampleCount >= configuration.minimumSamples,
              duration >= configuration.targetDuration else { return nil }
        return makeResult()
    }

    private func makeResult() -> PointMeasurementResult? {
        let medianEasting = median(samples.map(\.coordinate.easting))
        let medianNorthing = median(samples.map(\.coordinate.northing))
        let residuals = samples.map {
            hypot(
                $0.coordinate.easting - medianEasting,
                $0.coordinate.northing - medianNorthing
            )
        }
        let medianResidual = median(residuals)
        let medianAbsoluteDeviation = median(residuals.map { abs($0 - medianResidual) })
        let rejectionLimit = max(0.03, medianResidual + 3 * max(0.005, medianAbsoluteDeviation))
        let accepted = zip(samples, residuals)
            .filter { $0.1 <= rejectionLimit }
            .map { $0.0 }
        guard accepted.count >= configuration.minimumSamples else { return nil }

        let weights = accepted.map {
            1 / max(0.005, $0.combinedUncertainty * $0.combinedUncertainty)
        }
        let weightSum = weights.reduce(0, +)
        guard weightSum > 0 else { return nil }
        let easting = zip(accepted, weights).reduce(0) { $0 + $1.0.coordinate.easting * $1.1 } / weightSum
        let northing = zip(accepted, weights).reduce(0) { $0 + $1.0.coordinate.northing * $1.1 } / weightSum
        let spread = sqrt(zip(accepted, weights).reduce(0) {
            let distance = hypot(
                $1.0.coordinate.easting - easting,
                $1.0.coordinate.northing - northing
            )
            return $0 + $1.1 * distance * distance
        } / weightSum)
        let typicalUncertainty = median(accepted.map(\.combinedUncertainty))
        let tilts = accepted.map(\.tiltDegrees)
        let verticalResult = makeVerticalResult(from: accepted)
        guard !configuration.requiresAltitude || verticalResult != nil else { return nil }

        return PointMeasurementResult(
            coordinate: UTM32Projection.unproject(
                UTMCoordinate(easting: easting, northing: northing)
            ),
            altitudeMSL: verticalResult?.altitude,
            source: source,
            sampleCount: accepted.count,
            duration: duration,
            minimumTiltDegrees: tilts.min() ?? 0,
            meanTiltDegrees: tilts.reduce(0, +) / Double(tilts.count),
            horizontalSpread: spread,
            estimatedHorizontalAccuracy: max(spread, typicalUncertainty),
            verticalSpread: verticalResult?.spread,
            estimatedVerticalAccuracy: verticalResult?.accuracy,
            timestamp: accepted.last?.timestamp ?? Date()
        )
    }

    private func makeVerticalResult(
        from samples: [Sample]
    ) -> (altitude: Double, spread: Double, accuracy: Double)? {
        let altitudeSamples = samples.compactMap { sample in
            sample.altitudeMSL.map { (sample: sample, altitude: $0) }
        }
        guard altitudeSamples.count >= configuration.minimumSamples else { return nil }

        let medianAltitude = median(altitudeSamples.map(\.altitude))
        let deviations = altitudeSamples.map { abs($0.altitude - medianAltitude) }
        let medianAbsoluteDeviation = median(deviations)
        let rejectionLimit = max(0.05, 3 * max(0.01, 1.4826 * medianAbsoluteDeviation))
        let accepted = altitudeSamples.filter {
            abs($0.altitude - medianAltitude) <= rejectionLimit
        }
        guard accepted.count >= configuration.minimumSamples else { return nil }

        let weights = accepted.map {
            1 / ($0.sample.verticalUncertainty * $0.sample.verticalUncertainty)
        }
        let weightSum = weights.reduce(0, +)
        guard weightSum > 0 else { return nil }
        let altitude = zip(accepted, weights).reduce(0) {
            $0 + $1.0.altitude * $1.1
        } / weightSum
        let spread = sqrt(zip(accepted, weights).reduce(0) {
            let difference = $1.0.altitude - altitude
            return $0 + $1.1 * difference * difference
        } / weightSum)
        let typicalUncertainty = median(accepted.map(\.sample.verticalUncertainty))
        return (altitude, spread, max(spread, typicalUncertainty))
    }

    private func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? (sorted[middle - 1] + sorted[middle]) / 2
            : sorted[middle]
    }
}
