//
//  AudioOutputDevice.swift
//  AudioAnchor
//

import CoreAudio
import os

struct AudioOutputDevice {
    let id: AudioObjectID

    /// 入力専用のデバイスはメニューに出さないよう、出力チャンネルを持つものだけに絞る
    static var all: [AudioOutputDevice] {
        var address = AudioObjectPropertyAddress(selector: kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(.system, &address, 0, nil, &size) == noErr else {
            return []
        }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(.system, &address, 0, nil, &size, &ids) == noErr else {
            return []
        }
        return ids.map(AudioOutputDevice.init).filter { $0.outputChannelCount > 0 }
    }

    var name: String {
        var address = AudioObjectPropertyAddress(selector: kAudioObjectPropertyName)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, &name) == noErr,
            let name
        else {
            return ""
        }
        return name.takeRetainedValue() as String
    }

    private var outputChannelCount: Int {
        var address = AudioObjectPropertyAddress(selector: kAudioDevicePropertyStreamConfiguration, scope: kAudioObjectPropertyScopeOutput)
        var size: UInt32 = 0
        guard
            AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr,
            size > 0
        else {
            return 0
        }
        let bufferList = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { bufferList.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, bufferList) == noErr else {
            return 0
        }
        let buffers = UnsafeMutableAudioBufferListPointer(bufferList.assumingMemoryBound(to: AudioBufferList.self))
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    /// 通知音などのシステム出力も同じデバイスに揃えるため、両方を切り替える
    func setAsDefaultOutput() {
        for selector in [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDefaultSystemOutputDevice] {
            var address = AudioObjectPropertyAddress(selector: selector)
            var id = id
            let status = AudioObjectSetPropertyData(.system, &address, 0, nil, UInt32(MemoryLayout<AudioObjectID>.size), &id)
            if status != noErr {
                Logger.app.error("Failed to set default output device: \(status, privacy: .public)")
            }
        }
    }

    static func observeDeviceList(_ handler: @escaping () -> Void) -> AudioPropertyObservation {
        AudioPropertyObservation(objectID: .system, selector: kAudioHardwarePropertyDevices, handler: handler)
    }

    func observeIsRunningSomewhere(_ handler: @escaping () -> Void) -> AudioPropertyObservation {
        AudioPropertyObservation(objectID: id, selector: kAudioDevicePropertyDeviceIsRunningSomewhere, handler: handler)
    }
}

/// 解除には登録時と同じブロックを渡す必要があるため、ブロックごと保持し、解放されたときに解除する
final class AudioPropertyObservation {
    private let objectID: AudioObjectID
    private var address: AudioObjectPropertyAddress
    private let block: AudioObjectPropertyListenerBlock

    fileprivate init(objectID: AudioObjectID, selector: AudioObjectPropertySelector, handler: @escaping () -> Void) {
        self.objectID = objectID
        address = AudioObjectPropertyAddress(selector: selector)
        block = { _, _ in handler() }
        AudioObjectAddPropertyListenerBlock(objectID, &address, .main, block)
    }

    deinit {
        AudioObjectRemovePropertyListenerBlock(objectID, &address, .main, block)
    }
}

private extension AudioObjectID {
    static let system = AudioObjectID(kAudioObjectSystemObject)
}

private extension AudioObjectPropertyAddress {
    init(selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) {
        self.init(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
}

extension Logger {
    static let app = Logger(subsystem: Bundle.main.bundleIdentifier ?? "dev.wata.AudioAnchor", category: "app")
}
