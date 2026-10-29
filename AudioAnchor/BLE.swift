//
//  BLE.swift
//  AudioAnchor
//
//  Created by Wataru Nagasawa on 2021/09/20.
//

import Foundation
import CoreBluetooth

final class BLE: NSObject {
    private let centralManager: CBCentralManager
    private var devices = [UUID: CBPeripheral]()

    override init() {
        centralManager = CBCentralManager()
        super.init()
        centralManager.delegate = self
    }

    func startScanning() {
        guard !centralManager.isScanning else { return }
        centralManager.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
    }
}

extension BLE: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            print("Bluetooth powered on")
            startScanning()

        case .poweredOff:
            print("Bluetooth powered off")

        default:
            break
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String : Any],
                        rssi RSSI: NSNumber) {
//        let rssi = RSSI.intValue > 0 ? 0 : RSSI.intValue
        if let device = devices[peripheral.identifier] {
            return
        }
        devices[peripheral.identifier] = peripheral
        print("\(peripheral.name): \(peripheral.identifier.description)")

//        if let mac = device.macAddr {
//            let prettifiedMac = mac.replacingOccurrences(of: "-", with: ":").uppercased()
//            desc = String(format: "%@ (%@)", device.description, prettifiedMac)
//        } else {
//            desc = device.description
//        }

//        let dev = devices[peripheral.identifier]
//        var device: Device
//        if (dev == nil) {
//            device = Device(uuid: peripheral.identifier)
//            if (rssi >= thresholdRSSI) {
//                device.peripheral = peripheral
//                device.rssi = rssi
//                device.advData = advertisementData["kCBAdvDataManufacturerData"] as? Data
//                devices[peripheral.identifier] = device
//                central.connect(peripheral, options: nil)
//                delegate?.newDevice(device: device)
//            }
//        } else {
//            device = dev!
//            device.rssi = rssi
//            delegate?.updateDevice(device: device)
//        }
//        resetScanTimer(device: device)
    }
}
