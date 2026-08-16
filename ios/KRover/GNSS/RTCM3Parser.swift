import Foundation

struct RTCMFrame: Equatable {
    let data: Data
    let messageType: Int
}

final class RTCM3Parser {
    private var buffer = Data()
    private(set) var validFrames: UInt64 = 0
    private(set) var crcErrors: UInt64 = 0
    private(set) var discardedBytes: UInt64 = 0

    func reset() { buffer.removeAll(keepingCapacity: true) }

    func resetStatistics() {
        validFrames = 0
        crcErrors = 0
        discardedBytes = 0
    }

    func append(_ data: Data) -> [RTCMFrame] {
        buffer.append(data)
        var output: [RTCMFrame] = []

        while true {
            guard let preamble = buffer.firstIndex(of: 0xD3) else {
                discardedBytes += UInt64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                break
            }
            if preamble > buffer.startIndex {
                let count = buffer.distance(from: buffer.startIndex, to: preamble)
                discardedBytes += UInt64(count)
                buffer.removeFirst(count)
            }
            guard buffer.count >= 3 else { break }

            let bytes = [UInt8](buffer.prefix(3))
            let payloadLength = (Int(bytes[1] & 0x03) << 8) | Int(bytes[2])
            guard payloadLength >= 2 else {
                discardedBytes += 1
                buffer.removeFirst()
                continue
            }
            let frameLength = payloadLength + 6
            guard buffer.count >= frameLength else { break }

            let candidate = Data(buffer.prefix(frameLength))
            let expected = (UInt32(candidate[frameLength - 3]) << 16) |
                (UInt32(candidate[frameLength - 2]) << 8) |
                UInt32(candidate[frameLength - 1])
            let actual = Self.crc24q(candidate.prefix(frameLength - 3))
            if actual == expected {
                let messageType = payloadLength >= 2
                    ? (Int(candidate[3]) << 4) | (Int(candidate[4]) >> 4)
                    : 0
                validFrames += 1
                output.append(RTCMFrame(data: candidate, messageType: messageType))
                buffer.removeFirst(frameLength)
            } else {
                crcErrors += 1
                discardedBytes += 1
                buffer.removeFirst()
            }
        }
        return output
    }

    static func crc24q<S: Sequence>(_ bytes: S) -> UInt32 where S.Element == UInt8 {
        var crc: UInt32 = 0
        for byte in bytes {
            crc ^= UInt32(byte) << 16
            for _ in 0..<8 {
                crc <<= 1
                if crc & 0x1000000 != 0 { crc ^= 0x1864CFB }
            }
        }
        return crc & 0xFFFFFF
    }
}
