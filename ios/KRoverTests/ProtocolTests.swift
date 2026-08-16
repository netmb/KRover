import CoreLocation
import XCTest
@testable import KRover

final class ProtocolTests: XCTestCase {
    func testBLEHeaderRoundTrip() throws {
        let packet = RoverBLEProtocol.frame(payload: Data([1, 2, 3]), session: 7, sequence: 0x1234)
        let decoded = try XCTUnwrap(RoverBLEProtocol.decode(packet))
        XCTAssertEqual(decoded.0, .init(version: 1, session: 7, sequence: 0x1234))
        XCTAssertEqual(decoded.1, Data([1, 2, 3]))
    }

    func testIMUTelemetryDecoding() throws {
        let json = Data(#"{"v":1,"s":"simulation","x":true,"r":0.12,"p":-0.21,"t":0.24,"k":-90,"a":1.001,"g":0.03,"m":false,"l":true,"o":true,"c":true,"y":true,"q":"ready","n":50,"u":true,"d":12,"h":810,"e":3}"#.utf8)
        let state = try JSONDecoder().decode(IMUState.self, from: json)
        XCTAssertEqual(state.source, "simulation")
        XCTAssertTrue(state.isSimulation)
        XCTAssertEqual(state.totalTiltDegrees, 0.24, accuracy: 0.001)
        XCTAssertFalse(state.isMoving)
        XCTAssertTrue(state.measurementReady)
        XCTAssertTrue(state.hasDirectionCalibration)
        XCTAssertEqual(state.calibrationState, .ready)
        XCTAssertEqual(state.calibrationSamples, 50)
        XCTAssertEqual(state.markerDirectionDegrees, -90)
        XCTAssertEqual(state.stableMilliseconds, 810)
        XCTAssertEqual(state.readySequence, 3)
    }

    func testIMUTelemetryRemainsCompatibleWithoutNewTimingFields() throws {
        let json = Data(#"{"v":1,"s":"old","x":false,"r":0,"p":0,"t":0,"a":1,"g":0,"m":false,"l":true,"o":true,"c":true,"q":"ready","n":0,"u":true,"d":5}"#.utf8)
        let state = try JSONDecoder().decode(IMUState.self, from: json)
        XCTAssertNil(state.stableMilliseconds)
        XCTAssertNil(state.readySequence)
        XCTAssertNil(state.markerDirectionDegrees)
        XCTAssertNil(state.directionCalibrated)
        XCTAssertFalse(state.hasDirectionCalibration)
    }

    func testVerticalCalibrationCanBeReadyBeforeDirectionCalibration() throws {
        let json = Data(#"{"v":1,"s":"mpu6050","x":false,"r":0,"p":0,"t":0,"k":-90,"a":1,"g":0,"m":false,"l":true,"o":false,"c":true,"y":false,"q":"ready","n":0,"u":true,"d":5}"#.utf8)
        let state = try JSONDecoder().decode(IMUState.self, from: json)
        XCTAssertTrue(state.isCalibrated)
        XCTAssertFalse(state.hasDirectionCalibration)
        XCTAssertFalse(state.measurementReady)
        XCTAssertEqual(state.calibrationState, .ready)
    }

    func testRTCMParserHandlesChunksAndCRC() {
        let payload = Data([0x43, 0x20, 0x01, 0x02, 0x03]) // type 1074
        let frame = makeRTCM(payload: payload)
        let parser = RTCM3Parser()
        XCTAssertTrue(parser.append(frame.prefix(2)).isEmpty)
        let result = parser.append(frame.dropFirst(2))
        XCTAssertEqual(result, [RTCMFrame(data: frame, messageType: 1074)])
        XCTAssertEqual(parser.crcErrors, 0)
    }

    func testRTCMParserRecoversAfterCorruptFrame() {
        var corrupt = makeRTCM(payload: Data([0x3E, 0xD0, 0x00]))
        corrupt[4] ^= 0x01
        let valid = makeRTCM(payload: Data([0x43, 0x20]))
        let parser = RTCM3Parser()
        let result = parser.append(corrupt + valid)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].messageType, 1074)
        XCTAssertEqual(parser.crcErrors, 1)
    }

    func testRTCMParserRejectsFrameWithoutMessageType() {
        let parser = RTCM3Parser()
        XCTAssertTrue(parser.append(makeRTCM(payload: Data())).isEmpty)
        XCTAssertEqual(parser.validFrames, 0)
        XCTAssertGreaterThan(parser.discardedBytes, 0)
    }

    func testNtripChunkDecoderRejectsOverflowingLength() {
        let decoder = HTTPChunkDecoder()
        XCTAssertThrowsError(try decoder.append(Data("7FFFFFFFFFFFFFFF\r\n".utf8)))
    }

    func testNtripChunkDecoderRejectsOversizedLength() {
        let decoder = HTTPChunkDecoder()
        XCTAssertThrowsError(try decoder.append(Data("100001\r\n".utf8)))
    }

    func testNtripChunkDecoderRejectsUnterminatedSizeLine() {
        let decoder = HTTPChunkDecoder()
        XCTAssertThrowsError(try decoder.append(Data(repeating: 0x31, count: 1_025)))
    }

    func testNtripSettingsRejectRequestLineInjection() {
        var settings = NtripSettings(username: "user", password: "password")
        XCTAssertTrue(settings.hasValidRequestFields)
        settings.mountpoint = "VRS\r\nInjected: true"
        XCTAssertFalse(settings.hasValidRequestFields)
        settings.mountpoint = "VRS"
        settings.host = "caster.example\nInjected"
        XCTAssertFalse(settings.hasValidRequestFields)
    }

    func testNMEAParserReadsFixedPosition() {
        let parser = NMEAParser()
        var received: GNSSPosition?
        parser.onPosition = { received = $0 }
        let body = "GNGGA,123519.00,5000.000000,N,00900.000000,E,4,18,0.7,70.200,M,0.0,M,,"
        let checksum = body.utf8.reduce(UInt8(0), ^)
        parser.append(Data(String(format: "$%@*%02X\r\n", body, checksum).utf8))
        XCTAssertEqual(received?.fixQuality, .rtkFixed)
        XCTAssertEqual(received?.satellites, 18)
        XCTAssertEqual(received?.altitude ?? 0, 70.2, accuracy: 0.001)
        XCTAssertEqual(received?.coordinate.latitude ?? 0, 50.0, accuracy: 0.0000001)
        XCTAssertEqual(received?.coordinate.longitude ?? 0, 9.0, accuracy: 0.0000001)
    }

    func testUTM32MatchesSyntheticCentralMeridianCoordinate() {
        let coordinate = CLLocationCoordinate2D(latitude: 50.0, longitude: 9.0)
        let utm = UTM32Projection.project(coordinate)
        XCTAssertEqual(utm.easting, 500_000, accuracy: 0.001)
        XCTAssertEqual(utm.northing, 5_538_630.703, accuracy: 0.03)
    }

    func testUTM32RoundTripForRobustMeasurementMean() {
        let coordinate = CLLocationCoordinate2D(latitude: 50.0, longitude: 9.0)
        let roundTrip = UTM32Projection.unproject(UTM32Projection.project(coordinate))
        XCTAssertEqual(roundTrip.latitude, coordinate.latitude, accuracy: 1e-8)
        XCTAssertEqual(roundTrip.longitude, coordinate.longitude, accuracy: 1e-8)
    }

    func testPointMeasurementUsesRobustWeightedUTMMean() throws {
        let center = UTMCoordinate(easting: 500_000, northing: 5_538_630.703)
        var accumulator = PointMeasurementAccumulator(
            source: .roverRTK,
            configuration: .init(targetDuration: 2.5, minimumSamples: 8, poleLengthMeters: 2)
        )
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var result: PointMeasurementResult?
        for index in 0..<10 {
            let isOutlier = index == 4
            let eastingOffset = isOutlier ? 1.2 : Double((index % 3) - 1) * 0.004
            let northingOffset = isOutlier ? -0.9 : Double((index % 2) * 2 - 1) * 0.003
            let coordinate = UTM32Projection.unproject(UTMCoordinate(
                easting: center.easting + eastingOffset,
                northing: center.northing + northingOffset
            ))
            let position = GNSSPosition(
                coordinate: coordinate,
                altitude: index == 5 ? 89.5 : 88,
                horizontalSigma: 0.012,
                verticalSigma: 0.02,
                fixQuality: .rtkFixed,
                satellites: 24,
                hdop: 0.7,
                timestamp: start.addingTimeInterval(Double(index) * 0.35),
                sampleID: UInt64(index + 1)
            )
            result = accumulator.add(position: position, tiltDegrees: 0.2) ?? result
        }

        let measurement = try XCTUnwrap(result)
        let measuredUTM = UTM32Projection.project(measurement.coordinate)
        XCTAssertEqual(measuredUTM.easting, center.easting, accuracy: 0.01)
        XCTAssertEqual(measuredUTM.northing, center.northing, accuracy: 0.01)
        XCTAssertEqual(measurement.sampleCount, 9)
        XCTAssertLessThan(measurement.horizontalSpread, 0.01)
        XCTAssertGreaterThan(measurement.estimatedHorizontalAccuracy, 0.012)
        XCTAssertEqual(measurement.altitudeMSL ?? 0, 88, accuracy: 0.001)
        XCTAssertLessThan(measurement.verticalSpread ?? 1, 0.001)
        XCTAssertEqual(measurement.estimatedVerticalAccuracy ?? 0, 0.02, accuracy: 0.001)
    }

    func testRoverPointMeasurementUsesFiveShortGreenSamples() {
        let configuration = PointMeasurementAccumulator.Configuration.standard(
            for: .roverRTK,
            poleLengthMeters: 2
        )
        XCTAssertEqual(configuration.minimumSamples, 5)
        XCTAssertEqual(configuration.targetDuration, 0.35, accuracy: 0.001)
        XCTAssertEqual(configuration.minimumSampleSpacing, 0.075, accuracy: 0.001)
    }

    func testElevationMeasurementUsesLongerRTKAverage() {
        let configuration = PointMeasurementAccumulator.Configuration.elevation(
            for: .roverRTK,
            poleLengthMeters: 2
        )
        XCTAssertEqual(configuration.minimumSamples, 15)
        XCTAssertEqual(configuration.targetDuration, 2.0, accuracy: 0.001)
        XCTAssertEqual(configuration.minimumSampleSpacing, 0.075, accuracy: 0.001)
    }

    func testElevationMeasurementWaitsForEnoughValidHeights() throws {
        let center = UTMCoordinate(easting: 500_000, northing: 5_538_630.703)
        var accumulator = PointMeasurementAccumulator(
            source: .roverRTK,
            configuration: .elevation(for: .roverRTK, poleLengthMeters: 2)
        )
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var result: PointMeasurementResult?

        for index in 0..<16 {
            let position = GNSSPosition(
                coordinate: UTM32Projection.unproject(center),
                altitude: index == 7 ? 101.5 : 100,
                horizontalSigma: 0.012,
                verticalSigma: 0.02,
                fixQuality: .rtkFixed,
                satellites: 24,
                hdop: 0.7,
                timestamp: start.addingTimeInterval(Double(index) * 0.15),
                sampleID: UInt64(index + 1)
            )
            let nextResult = accumulator.add(position: position, tiltDegrees: 0.2)
            if index < 15 { XCTAssertNil(nextResult) }
            result = nextResult ?? result
        }

        let measurement = try XCTUnwrap(result)
        XCTAssertEqual(measurement.altitudeMSL ?? 0, 100, accuracy: 0.001)
    }

    func testRoverPointMeasurementThrottlesTwentyHertzToFiveUsefulSamples() throws {
        let center = UTMCoordinate(easting: 500_000, northing: 5_538_630.703)
        var accumulator = PointMeasurementAccumulator(
            source: .roverRTK,
            configuration: .standard(for: .roverRTK, poleLengthMeters: 2)
        )
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var result: PointMeasurementResult?
        for index in 0..<9 {
            let position = GNSSPosition(
                coordinate: UTM32Projection.unproject(center),
                altitude: 88,
                horizontalSigma: 0.012,
                verticalSigma: 0.02,
                fixQuality: .rtkFixed,
                satellites: 24,
                hdop: 0.7,
                timestamp: start.addingTimeInterval(Double(index) * 0.05),
                sampleID: UInt64(index + 1)
            )
            result = accumulator.add(position: position, tiltDegrees: 0.2) ?? result
        }

        XCTAssertEqual(accumulator.sampleCount, 5)
        let measurement = try XCTUnwrap(result)
        XCTAssertEqual(measurement.sampleCount, 5)
        XCTAssertGreaterThanOrEqual(measurement.duration, 0.35)
    }

    func testPoleCorrectionUsesMarkerRelativeDirections() {
        var state = IMUState()
        state.pitchDegrees = 2
        state.rollDegrees = 0.5
        var correction = PoleCorrection(imu: state)
        XCTAssertEqual(correction.deviationRightDegrees, -2, accuracy: 0.001)
        XCTAssertEqual(correction.rightDegrees, 2, accuracy: 0.001)
        XCTAssertEqual(correction.instruction, "Stabkopf nach rechts")

        state.pitchDegrees = 0.2
        state.rollDegrees = -3
        correction = PoleCorrection(imu: state)
        XCTAssertEqual(correction.deviationTowardUserDegrees, 3, accuracy: 0.001)
        XCTAssertEqual(correction.forwardDegrees, 3, accuracy: 0.001)
        XCTAssertEqual(correction.instruction, "Stabkopf nach vorn")
    }

    func testPoleCorrectionRotatesArbitrarySensorMountingToFixedMarkerView() {
        var state = IMUState()
        state.markerDirectionDegrees = -30
        // A 5° displacement toward a marker mounted at -30° in the sensor
        // plane must appear at the bottom of the fixed app view.
        state.pitchDegrees = 4.330127
        state.rollDegrees = -2.5

        let correction = PoleCorrection(imu: state)
        XCTAssertEqual(correction.deviationRightDegrees, 0, accuracy: 0.001)
        XCTAssertEqual(correction.deviationTowardUserDegrees, 5, accuracy: 0.001)
        XCTAssertEqual(correction.forwardDegrees, 5, accuracy: 0.001)
        XCTAssertEqual(correction.instruction, "Stabkopf nach vorn")
    }

    func testElevationSummaryFindsExtremaAndSlope() throws {
        let center = UTMCoordinate(easting: 500_000, northing: 5_538_630.703)
        let measurements = [
            makePointMeasurement(utm: center, altitude: 100.0, verticalAccuracy: 0.02),
            makePointMeasurement(
                utm: UTMCoordinate(easting: center.easting + 10, northing: center.northing),
                altitude: 99.6,
                verticalAccuracy: 0.03
            ),
            makePointMeasurement(
                utm: UTMCoordinate(easting: center.easting + 20, northing: center.northing),
                altitude: 100.2,
                verticalAccuracy: 0.02
            )
        ]

        let summary = try XCTUnwrap(ElevationMeasurementSummary(measurements: measurements))
        XCTAssertEqual(summary.highestPointIndex, 2)
        XCTAssertEqual(summary.lowestPointIndex, 1)
        XCTAssertEqual(summary.heightRange, 0.6, accuracy: 0.001)
        XCTAssertEqual(summary.startToEndHeightDifference, 0.2, accuracy: 0.001)
        XCTAssertEqual(summary.startToEndHorizontalDistance, 20, accuracy: 0.01)
        XCTAssertEqual(summary.startToEndSlopePercent ?? 0, 1, accuracy: 0.01)
        XCTAssertEqual(summary.estimatedRangeAccuracy ?? 0, hypot(0.02, 0.03), accuracy: 0.001)
    }

    func testMapLayerCatalogProvidesExtensibleDOPBackground() {
        XCTAssertEqual(MapBackgroundLayer.allCases, [.cadastre, .aerialDOP])
        XCTAssertTrue(NRWMapLayerCatalog.dopRGBTileTemplate.contains("LAYERS=nw_dop_rgb"))
        XCTAssertTrue(NRWMapLayerCatalog.dopRGBTileTemplate.contains("SRS=EPSG:3857"))
        XCTAssertTrue(NRWMapLayerCatalog.dopRGBTileTemplate.contains("{bbox-epsg-3857}"))
    }

    func testSignedTurnUsesShortestCompassDirection() {
        XCTAssertEqual(AppModel.signedTurn(targetBearing: 10, deviceHeading: 350), 20, accuracy: 0.001)
        XCTAssertEqual(AppModel.signedTurn(targetBearing: 350, deviceHeading: 10), -20, accuracy: 0.001)
        XCTAssertEqual(AppModel.signedTurn(targetBearing: 90, deviceHeading: 90), 0, accuracy: 0.001)
    }

    func testNtripDecoderAcceptsICYAndRawRTCM() throws {
        var accepted = false
        var body = Data()
        let decoder = NtripResponseDecoder(
            onAccepted: { accepted = true },
            onBody: { body.append($0) }
        )
        try decoder.append(Data("ICY 200 OK\r\nServer: test\r\n\r\n".utf8) + Data([0xD3, 0x00]))
        XCTAssertTrue(accepted)
        XCTAssertEqual(body, Data([0xD3, 0x00]))
    }

    func testNtripDecoderHandlesHTTPChunking() throws {
        var body = Data()
        let decoder = NtripResponseDecoder(onAccepted: {}, onBody: { body.append($0) })
        try decoder.append(Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n".utf8))
        try decoder.append(Data("2\r\nde\r\n0\r\n\r\n".utf8))
        XCTAssertEqual(String(data: body, encoding: .ascii), "abcde")
    }

    func testConfiguredNRWParcelAndExactGeometryLoad() async throws {
        let parcel = try await ParcelService().parcel(identifier: try integrationParcelID())
        XCTAssertFalse(parcel.district.isEmpty)
        XCTAssertFalse(parcel.section.isEmpty)
        XCTAssertFalse(parcel.number.isEmpty)
        XCTAssertGreaterThan(parcel.area ?? 0, 0)
        XCTAssertGreaterThan(parcel.wgs84Vertices.count, 3)
        XCTAssertEqual(parcel.wgs84Vertices.count, parcel.utmVertices.count)
        XCTAssertFalse(parcel.boundaryRings.isEmpty)
        XCTAssertEqual(parcel.boundaryRings[0].wgs84.count, parcel.boundaryRings[0].utm.count)
        let projectedFirstVertex = UTM32Projection.project(parcel.wgs84Vertices[0])
        XCTAssertEqual(parcel.utmVertices[0].easting, projectedFirstVertex.easting, accuracy: 0.01)
        XCTAssertEqual(parcel.utmVertices[0].northing, projectedFirstVertex.northing, accuracy: 0.01)
    }

    func testALKISPointLocationParserReadsOfficialCoordinateAndQuality() throws {
        let xml = Data(#"""
        <wfs:FeatureCollection xmlns:wfs="http://www.opengis.net/wfs/2.0"
            xmlns:adv="http://www.adv-online.de/namespaces/adv/gid/7.1"
            xmlns:gml="http://www.opengis.net/gml/3.2"
            xmlns:xlink="http://www.w3.org/1999/xlink"
            numberMatched="1" numberReturned="1">
          <wfs:member>
            <adv:AX_PunktortTA gml:id="TEST_POINT_001">
              <adv:lebenszeitintervall><adv:AA_Lebenszeitintervall>
                <adv:beginnt>2024-09-18T08:05:01Z</adv:beginnt>
              </adv:AA_Lebenszeitintervall></adv:lebenszeitintervall>
              <adv:istTeilVon xlink:href="urn:adv:oid:TEST_BOUNDARY_001"/>
              <adv:position><gml:Point srsName="urn:ogc:def:crs:EPSG::25832">
                <gml:pos>500000.000 5538630.703</gml:pos>
              </gml:Point></adv:position>
              <adv:kartendarstellung>true</adv:kartendarstellung>
              <adv:koordinatenstatus>1000</adv:koordinatenstatus>
              <adv:qualitaetsangaben><adv:AX_DQPunktort>
                <adv:genauigkeitsstufe>2100</adv:genauigkeitsstufe>
              </adv:AX_DQPunktort></adv:qualitaetsangaben>
            </adv:AX_PunktortTA>
          </wfs:member>
        </wfs:FeatureCollection>
        """#.utf8)

        let parsed = try BoundaryMarkerService.parsePointLocations(data: xml)
        XCTAssertEqual(parsed.numberMatched, 1)
        let point = try XCTUnwrap(parsed.records.first)
        XCTAssertEqual(point.id, "TEST_POINT_001")
        XCTAssertEqual(point.parentID, "TEST_BOUNDARY_001")
        XCTAssertEqual(point.utm.easting, 500_000, accuracy: 0.001)
        XCTAssertEqual(point.utm.northing, 5_538_630.703, accuracy: 0.001)
        XCTAssertEqual(point.isMapRepresentation, true)
        XCTAssertEqual(point.coordinateStatus, "1000")
        XCTAssertEqual(point.accuracyCode, "2100")
        XCTAssertEqual(point.updatedAt, "2024-09-18T08:05:01Z")
    }

    func testALKISBoundaryPointParserReadsMarkAndIndirectRelation() throws {
        let xml = Data(#"""
        <wfs:FeatureCollection xmlns:wfs="http://www.opengis.net/wfs/2.0"
            xmlns:adv="http://www.adv-online.de/namespaces/adv/gid/7.1"
            xmlns:gml="http://www.opengis.net/gml/3.2"
            xmlns:xlink="http://www.w3.org/1999/xlink">
          <wfs:member>
            <adv:AX_Grenzpunkt gml:id="TEST_BOUNDARY_001">
              <adv:bestehtAus xlink:href="urn:adv:oid:TEST_POINT_001"/>
              <adv:punktkennung>000000000000001</adv:punktkennung>
              <adv:abmarkung_Marke>1110</adv:abmarkung_Marke>
              <adv:festgestellterGrenzpunkt>true</adv:festgestellterGrenzpunkt>
              <adv:inversZu_zeigtAuf xlink:href="urn:adv:oid:TEST_INDIRECT_001"/>
            </adv:AX_Grenzpunkt>
          </wfs:member>
        </wfs:FeatureCollection>
        """#.utf8)

        let point = try XCTUnwrap(BoundaryMarkerService.parseBoundaryPoints(data: xml).first)
        XCTAssertEqual(point.id, "TEST_BOUNDARY_001")
        XCTAssertEqual(point.pointCode, "000000000000001")
        XCTAssertEqual(point.markCode, "1110")
        XCTAssertEqual(point.isEstablished, true)
        XCTAssertEqual(point.pointLocationIDs, ["TEST_POINT_001"])
        XCTAssertEqual(point.indirectMarkerIDs, ["TEST_INDIRECT_001"])
    }

    func testCadastralBoundaryPointDescribesMarkAccuracyAndOffset() {
        let point = CadastralBoundaryPoint(
            id: "indirect",
            boundaryPointID: "boundary",
            coordinate: UTM32Projection.unproject(
                UTMCoordinate(easting: 500_000.2, northing: 5_538_630.703)
            ),
            utm: UTMCoordinate(easting: 500_000.2, northing: 5_538_630.703),
            boundaryUTM: UTMCoordinate(easting: 500_000, northing: 5_538_630.703),
            pointCode: nil,
            markCode: "1110",
            isEstablished: true,
            isIntermediate: false,
            accuracyCode: "2100",
            updatedAt: nil,
            createdAt: nil,
            remark: nil,
            isIndirect: true
        )

        XCTAssertEqual(point.markStatus, .marked)
        XCTAssertEqual(point.markLabel, "Grenzstein")
        XCTAssertEqual(point.accuracyUpperBoundMeters ?? 0, 0.03, accuracy: 0.001)
        XCTAssertEqual(point.offsetFromBoundary, 0.2, accuracy: 0.001)
        XCTAssertTrue(point.navigationLabel.contains("0.200 m zurückgesetzt"))
    }

    func testConfiguredParcelLoadsActualALKISBoundaryPointObjects() async throws {
        let parcel = try await ParcelService().parcel(identifier: try integrationParcelID())
        let points = try await BoundaryMarkerService().boundaryPoints(for: parcel)

        XCTAssertFalse(points.isEmpty)
        XCTAssertTrue(points.allSatisfy { !$0.id.isEmpty && !$0.markCode.isEmpty })
        for point in points where !point.isIndirect {
            let nearestVertex = parcel.utmVertices.map {
                UTM32Projection.distance($0, point.boundaryUTM)
            }.min() ?? .greatestFiniteMagnitude
            XCTAssertLessThan(nearestVertex, 0.01)
        }
    }

    func testBoundarySnapperCapturesNearbyVertex() throws {
        let ring = makeBoundaryRing()
        let corner = ring.wgs84[0]
        let tap = CLLocationCoordinate2D(
            latitude: corner.latitude + 0.000001,
            longitude: corner.longitude + 0.000001
        )
        let target = try XCTUnwrap(BoundarySnapper.snap(tap, to: [ring]))
        XCTAssertEqual(target.kind, .vertex)
        XCTAssertEqual(target.utm, ring.utm[0])
        XCTAssertLessThan(target.snapDistance, 1.0)
    }

    func testBoundarySnapperProjectsOntoEdge() throws {
        let ring = makeBoundaryRing()
        let tap = CLLocationCoordinate2D(latitude: 49.99998, longitude: 7.0005)
        let target = try XCTUnwrap(BoundarySnapper.snap(tap, to: [ring]))
        XCTAssertEqual(target.kind, .edge)
        XCTAssertEqual(target.ringIndex, 0)
        XCTAssertEqual(target.segmentIndex, 0)

        let start = ring.utm[0]
        let end = ring.utm[1]
        let crossProduct =
            (target.utm.easting - start.easting) * (end.northing - start.northing) -
            (target.utm.northing - start.northing) * (end.easting - start.easting)
        XCTAssertEqual(crossProduct, 0, accuracy: 0.001)
    }

    func testPolygonEditorInsertsPointBetweenSelectedVertices() throws {
        let polygon = makeBoundaryRing().wgs84
        let insertedPoint = CLLocationCoordinate2D(latitude: 49.999998, longitude: 7.0005)
        let result = try XCTUnwrap(
            PolygonEditor.inserting(insertedPoint, afterEdgeStartingAt: 0, in: polygon)
        )

        XCTAssertEqual(result.count, polygon.count + 1)
        XCTAssertEqual(result[0].latitude, polygon[0].latitude, accuracy: 1e-12)
        XCTAssertEqual(result[1].latitude, insertedPoint.latitude, accuracy: 1e-12)
        XCTAssertEqual(result[1].longitude, insertedPoint.longitude, accuracy: 1e-12)
        XCTAssertEqual(result[2].longitude, polygon[1].longitude, accuracy: 1e-12)
    }

    func testPolygonEditorInsertsIntoClosingEdgeAtEnd() throws {
        let polygon = makeBoundaryRing().wgs84
        let insertedPoint = CLLocationCoordinate2D(latitude: 50.0005, longitude: 6.999998)
        let result = try XCTUnwrap(
            PolygonEditor.inserting(insertedPoint, afterEdgeStartingAt: 3, in: polygon)
        )

        XCTAssertEqual(result.count, polygon.count + 1)
        XCTAssertEqual(result.last?.latitude ?? 0, insertedPoint.latitude, accuracy: 1e-12)
        XCTAssertEqual(result.last?.longitude ?? 0, insertedPoint.longitude, accuracy: 1e-12)
    }

    func testPolygonEditorFindsNearestExistingEdge() throws {
        let polygon = makeBoundaryRing().wgs84
        let rover = CLLocationCoordinate2D(latitude: 49.999998, longitude: 7.0005)
        let match = try XCTUnwrap(PolygonEditor.nearestEdge(to: rover, in: polygon))

        XCTAssertEqual(match.startIndex, 0)
        XCTAssertEqual(match.endIndex, 1)
        XCTAssertTrue(match.projectionIsWithinSegment)
        XCTAssertLessThan(match.distance, 0.3)
    }

    func testPolygonEditorDetectsSelfIntersection() {
        let bowTie = [
            CLLocationCoordinate2D(latitude: 50.0, longitude: 7.0),
            CLLocationCoordinate2D(latitude: 50.001, longitude: 7.001),
            CLLocationCoordinate2D(latitude: 50.001, longitude: 7.0),
            CLLocationCoordinate2D(latitude: 50.0, longitude: 7.001)
        ]

        XCTAssertTrue(PolygonEditor.hasSelfIntersections(bowTie))
        XCTAssertFalse(PolygonEditor.hasSelfIntersections(makeBoundaryRing().wgs84))
    }

    private func integrationParcelID() throws -> String {
        guard let value = ProcessInfo.processInfo.environment["KROVER_INTEGRATION_PARCEL_ID"],
              !value.isEmpty else {
            throw XCTSkip(
                "Set KROVER_INTEGRATION_PARCEL_ID to run live NRW cadastral integration tests."
            )
        }
        return value
    }

    private func makeRTCM(payload: Data) -> Data {
        var frame = Data([0xD3, UInt8((payload.count >> 8) & 0x03), UInt8(payload.count & 0xff)])
        frame.append(payload)
        let crc = RTCM3Parser.crc24q(frame)
        frame.append(contentsOf: [UInt8(crc >> 16), UInt8((crc >> 8) & 0xff), UInt8(crc & 0xff)])
        return frame
    }

    private func makePointMeasurement(
        utm: UTMCoordinate,
        altitude: Double,
        verticalAccuracy: Double
    ) -> PointMeasurementResult {
        PointMeasurementResult(
            coordinate: UTM32Projection.unproject(utm),
            altitudeMSL: altitude,
            source: .roverRTK,
            sampleCount: 15,
            duration: 2,
            minimumTiltDegrees: 0.1,
            meanTiltDegrees: 0.2,
            horizontalSpread: 0.01,
            estimatedHorizontalAccuracy: 0.02,
            verticalSpread: 0.01,
            estimatedVerticalAccuracy: verticalAccuracy,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private func makeBoundaryRing() -> ParcelBoundaryRing {
        let coordinates = [
            CLLocationCoordinate2D(latitude: 50.0, longitude: 7.0),
            CLLocationCoordinate2D(latitude: 50.0, longitude: 7.001),
            CLLocationCoordinate2D(latitude: 50.001, longitude: 7.001),
            CLLocationCoordinate2D(latitude: 50.001, longitude: 7.0)
        ]
        return ParcelBoundaryRing(wgs84: coordinates, utm: coordinates.map(UTM32Projection.project))
    }
}
