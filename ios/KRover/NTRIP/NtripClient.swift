import Combine
import Foundation
import Network

final class NtripClient: ObservableObject {
    @Published private(set) var state: NtripState = .idle
    @Published private(set) var statistics = NtripStatistics()

    var onRTCMFrame: ((RTCMFrame) -> Void)?
    var ggaProvider: (() -> String?)?

    private let queue = DispatchQueue(label: "de.krover.ntrip")
    private var connection: NWConnection?
    private var settings: NtripSettings?
    private var shouldRun = false
    private var lifecycle = 0
    private var retryAttempt = 0
    private var parser = RTCM3Parser()
    private var decoder: NtripResponseDecoder?
    private var receivedBytes: UInt64 = 0
    private var lastFrameAt: Date?
    private let deliveryLock = NSLock()
    private var pendingRTCMFrames: [RTCMFrame] = []
    private var pendingStatistics: NtripStatistics?
    private var deliveryScheduled = false
    private var deliveryLifecycle: Int?

    private static let maximumPendingRTCMFrames = 256

    func start(settings: NtripSettings) {
        queue.async { [weak self] in
            guard let self else { return }
            self.stopInternal(publish: false)
            guard settings.hasValidRequestFields else {
                self.publishState(.failed("Ungültige Caster-Einstellungen"))
                return
            }
            self.settings = settings
            self.shouldRun = true
            self.lifecycle += 1
            self.retryAttempt = 0
            self.parser = RTCM3Parser()
            self.receivedBytes = 0
            self.lastFrameAt = nil
            DispatchQueue.main.async { self.statistics = NtripStatistics() }
            self.open(settings: settings, lifecycle: self.lifecycle)
        }
    }

    func stop() {
        queue.async { [weak self] in self?.stopInternal(publish: true) }
    }

    private func stopInternal(publish: Bool) {
        shouldRun = false
        lifecycle += 1
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        settings = nil
        decoder = nil
        parser.reset()
        resetFrameDelivery()
        if publish { publishState(.idle) }
    }

    private func open(settings: NtripSettings, lifecycle token: Int) {
        guard shouldRun, token == lifecycle,
              let port = NWEndpoint.Port(rawValue: settings.port) else { return }
        publishState(.connecting)

        let connection = NWConnection(host: NWEndpoint.Host(settings.host), port: port, using: .tcp)
        self.connection = connection
        decoder = NtripResponseDecoder(
            onAccepted: { [weak self] in
                self?.retryAttempt = 0
                self?.publishState(.streaming)
            },
            onBody: { [weak self] data in self?.processBody(data, lifecycle: token) }
        )

        connection.stateUpdateHandler = { [weak self, weak connection] newState in
            guard let self, let connection, self.connection === connection,
                  token == self.lifecycle else { return }
            switch newState {
            case .ready:
                guard self.sendInitialRequest(
                    settings: settings,
                    on: connection,
                    lifecycle: token
                ) else { return }
                self.receive(on: connection, lifecycle: token)
                self.scheduleGGA(on: connection, lifecycle: token)
            case .failed(let error): self.connectionFailed(error.localizedDescription, lifecycle: token)
            case .cancelled: break
            default: break
            }
        }
        connection.start(queue: queue)
    }

    private func sendInitialRequest(
        settings: NtripSettings,
        on connection: NWConnection,
        lifecycle token: Int
    ) -> Bool {
        let credentials = Data("\(settings.username):\(settings.password)".utf8).base64EncodedString()
        let mountpoint = settings.mountpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let gga = currentGGA() else {
            connectionFailed("Keine aktuelle Rover- oder Telefonposition für den Caster verfügbar", lifecycle: token)
            return false
        }
        let request = [
            "GET /\(mountpoint) HTTP/1.1",
            "Host: \(settings.host):\(settings.port)",
            "Ntrip-Version: Ntrip/2.0",
            "User-Agent: NTRIP KRover/0.1",
            "Authorization: Basic \(credentials)",
            "Ntrip-GGA: \(gga)",
            "Connection: close",
            "",
            ""
        ].joined(separator: "\r\n")
        connection.send(content: Data(request.utf8), completion: .contentProcessed { [weak self, weak connection] error in
            guard let self, let connection, self.connection === connection,
                  token == self.lifecycle else { return }
            if let error { self.connectionFailed(error.localizedDescription, lifecycle: token) }
        })
        return true
    }

    private func receive(on connection: NWConnection, lifecycle token: Int) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self, weak connection] data, _, complete, error in
            guard let self, let connection, self.connection === connection,
                  token == self.lifecycle else { return }
            do {
                if let data, !data.isEmpty { try self.decoder?.append(data) }
            } catch {
                self.connectionFailed(error.localizedDescription, lifecycle: token)
                return
            }
            if let error {
                self.connectionFailed(error.localizedDescription, lifecycle: token)
            } else if complete {
                self.connectionFailed("Verbindung vom Caster beendet", lifecycle: token)
            } else {
                self.receive(on: connection, lifecycle: token)
            }
        }
    }

    private func processBody(_ data: Data, lifecycle token: Int) {
        let frames = parser.append(data)
        receivedBytes += UInt64(data.count)
        if !frames.isEmpty { lastFrameAt = Date() }
        let snapshot = NtripStatistics(
            bytes: receivedBytes,
            validFrames: parser.validFrames,
            crcErrors: parser.crcErrors,
            lastFrameAt: lastFrameAt
        )
        enqueueFrameDelivery(frames, statistics: snapshot, lifecycle: token)
    }

    private func enqueueFrameDelivery(
        _ frames: [RTCMFrame],
        statistics: NtripStatistics,
        lifecycle token: Int
    ) {
        deliveryLock.lock()
        if deliveryLifecycle != nil, deliveryLifecycle != token {
            pendingRTCMFrames.removeAll(keepingCapacity: true)
            pendingStatistics = nil
            deliveryScheduled = false
        }
        deliveryLifecycle = token
        pendingRTCMFrames.append(contentsOf: frames)
        if pendingRTCMFrames.count > Self.maximumPendingRTCMFrames {
            pendingRTCMFrames.removeFirst(pendingRTCMFrames.count - Self.maximumPendingRTCMFrames)
        }
        pendingStatistics = statistics
        let shouldSchedule = !deliveryScheduled
        deliveryScheduled = true
        deliveryLock.unlock()

        guard shouldSchedule else { return }
        DispatchQueue.main.async { [weak self] in self?.deliverPendingFrames(lifecycle: token) }
    }

    private func deliverPendingFrames(lifecycle token: Int) {
        deliveryLock.lock()
        guard deliveryScheduled, deliveryLifecycle == token else {
            deliveryLock.unlock()
            return
        }
        let frames = pendingRTCMFrames
        let snapshot = pendingStatistics
        pendingRTCMFrames.removeAll(keepingCapacity: true)
        pendingStatistics = nil
        deliveryScheduled = false
        deliveryLifecycle = nil
        deliveryLock.unlock()

        if let snapshot { statistics = snapshot }
        frames.forEach { onRTCMFrame?($0) }
    }

    private func resetFrameDelivery() {
        deliveryLock.lock()
        pendingRTCMFrames.removeAll(keepingCapacity: true)
        pendingStatistics = nil
        deliveryScheduled = false
        deliveryLifecycle = nil
        deliveryLock.unlock()
    }

    private func scheduleGGA(on connection: NWConnection, lifecycle token: Int) {
        queue.asyncAfter(deadline: .now() + 10) { [weak self, weak connection] in
            guard let self, let connection, self.connection === connection,
                  self.shouldRun, token == self.lifecycle else { return }
            if let gga = self.currentGGA() {
                connection.send(content: Data("\(gga)\r\n".utf8), completion: .idempotent)
            }
            self.scheduleGGA(on: connection, lifecycle: token)
        }
    }

    private func currentGGA() -> String? {
        var value: String?
        DispatchQueue.main.sync { value = ggaProvider?() }
        return value
    }

    private func connectionFailed(_ message: String, lifecycle token: Int) {
        guard shouldRun, token == lifecycle, connection != nil else { return }
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        decoder = nil
        retryAttempt += 1
        let delay = min(30, Int(pow(2.0, Double(min(retryAttempt - 1, 5)))))
        publishState(.retrying(delay, message))
        guard let settings else { return }
        queue.asyncAfter(deadline: .now() + .seconds(delay)) { [weak self] in
            guard let self, self.shouldRun, token == self.lifecycle else { return }
            self.open(settings: settings, lifecycle: token)
        }
    }

    private func publishState(_ newState: NtripState) {
        DispatchQueue.main.async { [weak self] in self?.state = newState }
    }
}

final class NtripResponseDecoder {
    enum DecodeError: LocalizedError {
        case headerTooLarge
        case malformedResponse
        case rejected(String)
        case malformedChunk

        var errorDescription: String? {
            switch self {
            case .headerTooLarge: return "NTRIP-Antwortkopf zu groß"
            case .malformedResponse: return "Ungültige NTRIP-Antwort"
            case .rejected(let status): return "Caster lehnt Verbindung ab (\(status))"
            case .malformedChunk: return "Ungültige HTTP-Chunk-Kodierung"
            }
        }
    }

    private var headerBuffer = Data()
    private var accepted = false
    private var isChunked = false
    private let chunkDecoder = HTTPChunkDecoder()
    private let onAccepted: () -> Void
    private let onBody: (Data) -> Void

    init(onAccepted: @escaping () -> Void, onBody: @escaping (Data) -> Void) {
        self.onAccepted = onAccepted
        self.onBody = onBody
    }

    func append(_ data: Data) throws {
        if accepted {
            try emitBody(data)
            return
        }
        headerBuffer.append(data)
        guard headerBuffer.count <= 65_536 else { throw DecodeError.headerTooLarge }
        let delimiter = Data("\r\n\r\n".utf8)
        guard let range = headerBuffer.range(of: delimiter) else { return }
        let headerData = headerBuffer[..<range.lowerBound]
        let remainder = Data(headerBuffer[range.upperBound...])
        guard let header = String(data: headerData, encoding: .isoLatin1) else {
            throw DecodeError.malformedResponse
        }
        let lines = header.components(separatedBy: "\r\n")
        guard let status = lines.first,
              status.hasPrefix("HTTP/") || status.hasPrefix("ICY ") else {
            throw DecodeError.malformedResponse
        }
        let fields = status.split(separator: " ")
        guard fields.count >= 2, fields[1] == "200" else { throw DecodeError.rejected(status) }
        isChunked = lines.dropFirst().contains {
            $0.lowercased().hasPrefix("transfer-encoding:") && $0.lowercased().contains("chunked")
        }
        accepted = true
        headerBuffer.removeAll()
        onAccepted()
        if !remainder.isEmpty { try emitBody(remainder) }
    }

    private func emitBody(_ data: Data) throws {
        if isChunked {
            for part in try chunkDecoder.append(data) where !part.isEmpty { onBody(part) }
        } else {
            onBody(data)
        }
    }
}

final class HTTPChunkDecoder {
    private static let maximumChunkLineLength = 1_024
    private static let maximumChunkLength = 1_048_576
    private static let maximumBufferedBytes = maximumChunkLength + 65_536 + 2

    private var buffer = Data()
    private var expectedLength: Int?
    private var finished = false

    func append(_ data: Data) throws -> [Data] {
        guard !finished else { return [] }
        buffer.append(data)
        guard buffer.count <= Self.maximumBufferedBytes else {
            throw NtripResponseDecoder.DecodeError.malformedChunk
        }
        var output: [Data] = []

        while true {
            if expectedLength == nil {
                guard let lineEnd = buffer.range(of: Data("\r\n".utf8)) else {
                    guard buffer.count <= Self.maximumChunkLineLength else {
                        throw NtripResponseDecoder.DecodeError.malformedChunk
                    }
                    break
                }
                guard lineEnd.lowerBound <= Self.maximumChunkLineLength else {
                    throw NtripResponseDecoder.DecodeError.malformedChunk
                }
                guard let line = String(data: buffer[..<lineEnd.lowerBound], encoding: .ascii),
                      let length = Int(line.split(separator: ";", maxSplits: 1)[0], radix: 16),
                      length <= Self.maximumChunkLength else {
                    throw NtripResponseDecoder.DecodeError.malformedChunk
                }
                buffer.removeSubrange(..<lineEnd.upperBound)
                if length == 0 {
                    finished = true
                    break
                }
                expectedLength = length
            }
            guard let expectedLength else { continue }
            let (requiredBytes, overflow) = expectedLength.addingReportingOverflow(2)
            guard !overflow else { throw NtripResponseDecoder.DecodeError.malformedChunk }
            guard buffer.count >= requiredBytes else { break }
            let chunkAndTerminator = Data(buffer.prefix(requiredBytes))
            let payload = Data(chunkAndTerminator.prefix(expectedLength))
            guard chunkAndTerminator.suffix(2).elementsEqual([0x0D, 0x0A]) else {
                throw NtripResponseDecoder.DecodeError.malformedChunk
            }
            output.append(payload)
            buffer.removeFirst(requiredBytes)
            self.expectedLength = nil
        }
        return output
    }
}
