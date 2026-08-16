import Combine
import CoreBluetooth
import Foundation

final class BLERoverManager: NSObject, ObservableObject {
    @Published private(set) var state: ConnectionState = .idle
    @Published private(set) var roverStatus = RoverStatus()
    @Published private(set) var imuState = IMUState()
    @Published private(set) var latestPosition: GNSSPosition?
    @Published private(set) var latestGGA: String?
    @Published private(set) var pendingRTCMChunks = 0
    @Published private(set) var localSequenceGaps: UInt64 = 0
    @Published private(set) var droppedRTCMChunks: UInt64 = 0

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var rtcmCharacteristic: CBCharacteristic?
    private var gnssCharacteristic: CBCharacteristic?
    private var statusCharacteristic: CBCharacteristic?
    private var controlCharacteristic: CBCharacteristic?
    private var imuCharacteristic: CBCharacteristic?
    private let nmeaParser = NMEAParser()

    private var wantsConnection = false
    private var rtcmQueue: [Data] = []
    private var rtcmQueueHead = 0
    private var rtcmSequence: UInt16 = 0
    private var rtcmSession = UInt8.random(in: 1...255)
    private var remoteCredits = 0
    private var incomingSession: UInt8?
    private var incomingSequence: UInt16?

    override init() {
        super.init()
        nmeaParser.onPosition = { [weak self] position in self?.latestPosition = position }
        nmeaParser.onGGA = { [weak self] sentence in self?.latestGGA = sentence }
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func connect() {
        wantsConnection = true
        guard central.state == .poweredOn else {
            updateBluetoothState(central.state)
            return
        }
        startScanning()
    }

    func disconnect() {
        wantsConnection = false
        central.stopScan()
        if let peripheral { central.cancelPeripheralConnection(peripheral) }
        clearConnection()
        state = .idle
    }

    func enqueueRTCM(frame: Data) {
        guard state.isConnected, let peripheral, rtcmCharacteristic != nil else { return }
        let maximum = max(20, peripheral.maximumWriteValueLength(for: .withoutResponse))
        let payloadLength = max(1, maximum - RoverBLEProtocol.headerLength)
        var offset = 0
        while offset < frame.count {
            let end = min(offset + payloadLength, frame.count)
            rtcmQueue.append(Data(frame[offset..<end]))
            offset = end
        }
        if queuedRTCMChunkCount > 256 {
            let overflow = queuedRTCMChunkCount - 256
            rtcmQueueHead += overflow
            droppedRTCMChunks += UInt64(overflow)
            compactRTCMQueueIfNeeded()
        }
        pendingRTCMChunks = queuedRTCMChunkCount
        pumpRTCM()
    }

    func setDummyMode(_ mode: String) {
        sendControl(["mode": mode])
    }

    func resetRoverStatistics() {
        sendControl(["resetStats": true])
    }

    func setIMUSimulationMode(_ mode: String) {
        sendControl(["imuMode": mode])
    }

    func calibrateIMU() {
        sendControl(["calibrateImu": true])
    }

    func calibrateIMUDirection() {
        sendControl(["calibrateImuDirection": true])
    }

    func resetIMUCalibration() {
        sendControl(["resetImuCalibration": true])
    }

    private func sendControl(_ object: [String: Any]) {
        guard let peripheral, let controlCharacteristic,
              let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        peripheral.writeValue(data, for: controlCharacteristic, type: .withResponse)
    }

    private func startScanning() {
        guard !central.isScanning else { return }
        state = .scanning
        central.scanForPeripherals(
            withServices: [RoverBLEProtocol.service],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
    }

    private func clearConnection() {
        peripheral = nil
        rtcmCharacteristic = nil
        gnssCharacteristic = nil
        statusCharacteristic = nil
        controlCharacteristic = nil
        imuCharacteristic = nil
        rtcmQueue.removeAll()
        rtcmQueueHead = 0
        pendingRTCMChunks = 0
        remoteCredits = 0
        incomingSession = nil
        incomingSequence = nil
        nmeaParser.reset()
        latestPosition = nil
        latestGGA = nil
        imuState = IMUState()
    }

    private func pumpRTCM() {
        guard let peripheral, let characteristic = rtcmCharacteristic else { return }
        while queuedRTCMChunkCount > 0 && remoteCredits > 0 && peripheral.canSendWriteWithoutResponse {
            let payload = rtcmQueue[rtcmQueueHead]
            rtcmQueueHead += 1
            let packet = RoverBLEProtocol.frame(
                payload: payload,
                session: rtcmSession,
                sequence: rtcmSequence
            )
            rtcmSequence &+= 1
            remoteCredits -= 1
            peripheral.writeValue(packet, for: characteristic, type: .withoutResponse)
        }
        compactRTCMQueueIfNeeded()
        pendingRTCMChunks = queuedRTCMChunkCount
    }

    private var queuedRTCMChunkCount: Int {
        rtcmQueue.count - rtcmQueueHead
    }

    private func compactRTCMQueueIfNeeded() {
        if rtcmQueueHead == rtcmQueue.count {
            rtcmQueue.removeAll(keepingCapacity: true)
            rtcmQueueHead = 0
        } else if rtcmQueueHead >= 128, rtcmQueueHead * 2 >= rtcmQueue.count {
            rtcmQueue.removeFirst(rtcmQueueHead)
            rtcmQueueHead = 0
        }
    }

    private func processGNSS(_ data: Data) {
        guard let (header, payload) = RoverBLEProtocol.decode(data),
              header.version == RoverBLEProtocol.version else { return }
        if incomingSession != header.session {
            incomingSession = header.session
            incomingSequence = header.sequence
            nmeaParser.reset()
        } else if let previous = incomingSequence, header.sequence != previous &+ 1 {
            localSequenceGaps += 1
            nmeaParser.reset()
        }
        incomingSequence = header.sequence
        nmeaParser.append(payload)
    }

    private func processStatus(_ data: Data) {
        guard let decoded = try? JSONDecoder().decode(RoverStatus.self, from: data) else { return }
        roverStatus = decoded
        remoteCredits = max(0, decoded.freeQueueSlots)
        pumpRTCM()
    }

    private func processIMU(_ data: Data) {
        guard let decoded = try? JSONDecoder().decode(IMUState.self, from: data) else { return }
        imuState = decoded
    }

    private func updateBluetoothState(_ bluetoothState: CBManagerState) {
        switch bluetoothState {
        case .poweredOn:
            state = .idle
            if wantsConnection { startScanning() }
        case .poweredOff: state = .unavailable("ausgeschaltet")
        case .unauthorized: state = .unavailable("nicht erlaubt")
        case .unsupported: state = .unavailable("nicht unterstützt")
        case .resetting: state = .unavailable("wird zurückgesetzt")
        case .unknown: state = .unavailable("Status unbekannt")
        @unknown default: state = .unavailable("Status unbekannt")
        }
    }
}

extension BLERoverManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        updateBluetoothState(central.state)
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        guard wantsConnection, self.peripheral == nil else { return }
        central.stopScan()
        self.peripheral = peripheral
        peripheral.delegate = self
        let name = peripheral.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? "KRover"
        state = .connecting(name)
        central.connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        rtcmSession &+= 1
        if rtcmSession == 0 { rtcmSession = 1 }
        rtcmSequence = 0
        peripheral.discoverServices([RoverBLEProtocol.service])
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        state = .failed(error?.localizedDescription ?? "Verbindung fehlgeschlagen")
        clearConnection()
        retryIfWanted()
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        clearConnection()
        state = error.map { .failed($0.localizedDescription) } ?? .idle
        retryIfWanted()
    }

    private func retryIfWanted() {
        guard wantsConnection else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard self?.wantsConnection == true else { return }
            self?.startScanning()
        }
    }
}

extension BLERoverManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil,
              let service = peripheral.services?.first(where: { $0.uuid == RoverBLEProtocol.service }) else {
            state = .failed(error?.localizedDescription ?? "BLE-Dienst fehlt")
            central.cancelPeripheralConnection(peripheral)
            return
        }
        peripheral.discoverCharacteristics(
            [
                RoverBLEProtocol.rtcmRX, RoverBLEProtocol.gnssTX,
                RoverBLEProtocol.status, RoverBLEProtocol.control, RoverBLEProtocol.imuTX
            ],
            for: service
        )
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard error == nil else {
            state = .failed(error?.localizedDescription ?? "BLE-Merkmale fehlen")
            central.cancelPeripheralConnection(peripheral)
            return
        }
        for characteristic in service.characteristics ?? [] {
            switch characteristic.uuid {
            case RoverBLEProtocol.rtcmRX: rtcmCharacteristic = characteristic
            case RoverBLEProtocol.gnssTX:
                gnssCharacteristic = characteristic
                peripheral.setNotifyValue(true, for: characteristic)
            case RoverBLEProtocol.status:
                statusCharacteristic = characteristic
                peripheral.setNotifyValue(true, for: characteristic)
                peripheral.readValue(for: characteristic)
            case RoverBLEProtocol.control: controlCharacteristic = characteristic
            case RoverBLEProtocol.imuTX:
                imuCharacteristic = characteristic
                peripheral.setNotifyValue(true, for: characteristic)
                peripheral.readValue(for: characteristic)
            default: break
            }
        }
        guard rtcmCharacteristic != nil, gnssCharacteristic != nil,
              statusCharacteristic != nil, controlCharacteristic != nil else {
            state = .failed("BLE-Protokoll unvollständig")
            central.cancelPeripheralConnection(peripheral)
            return
        }
        remoteCredits = 2
        state = .connected(peripheral.name ?? "KRover")
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, let data = characteristic.value else { return }
        if characteristic.uuid == RoverBLEProtocol.gnssTX { processGNSS(data) }
        if characteristic.uuid == RoverBLEProtocol.status { processStatus(data) }
        if characteristic.uuid == RoverBLEProtocol.imuTX { processIMU(data) }
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        pumpRTCM()
    }
}
