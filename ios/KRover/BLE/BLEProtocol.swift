import CoreBluetooth
import Foundation

enum RoverBLEProtocol {
    static let version: UInt8 = 1
    static let service = CBUUID(string: "7A1E0001-9B6D-4C7A-8F21-6D3E5C790001")
    static let rtcmRX = CBUUID(string: "7A1E0002-9B6D-4C7A-8F21-6D3E5C790001")
    static let gnssTX = CBUUID(string: "7A1E0003-9B6D-4C7A-8F21-6D3E5C790001")
    static let status = CBUUID(string: "7A1E0004-9B6D-4C7A-8F21-6D3E5C790001")
    static let control = CBUUID(string: "7A1E0005-9B6D-4C7A-8F21-6D3E5C790001")
    static let imuTX = CBUUID(string: "7A1E0006-9B6D-4C7A-8F21-6D3E5C790001")
    static let headerLength = 4

    struct Header: Equatable {
        let version: UInt8
        let session: UInt8
        let sequence: UInt16
    }

    static func frame(payload: Data, session: UInt8, sequence: UInt16) -> Data {
        var output = Data([version, session, UInt8(sequence & 0xff), UInt8(sequence >> 8)])
        output.append(payload)
        return output
    }

    static func decode(_ data: Data) -> (Header, Data)? {
        guard data.count >= headerLength else { return nil }
        let bytes = [UInt8](data.prefix(headerLength))
        let sequence = UInt16(bytes[2]) | (UInt16(bytes[3]) << 8)
        return (Header(version: bytes[0], session: bytes[1], sequence: sequence), Data(data.dropFirst(headerLength)))
    }
}
