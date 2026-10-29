//
//  AppDelegate.swift
//  AudioAnchor
//
//  Created by Wataru Nagasawa on 2021/07/30.
//

import Cocoa
import Sparkle
import SimplyCoreAudio
import LaunchAtLogin
import IOBluetooth

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let simply = SimplyCoreAudio()
    private let updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    private var deviceListObserver: NSObjectProtocol?
    private var deviceObservers = [NSObjectProtocol]()
    // 通知のたびに接続要求を重ねないよう、接続を試している機器を持っておく
    private var connectingDevice: IOBluetoothDevice?
    private lazy var currentDevices = simply.allOutputDevices
    private lazy var statusItem: NSStatusItem = {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let image = NSImage(named: "Icon")!
        image.size = .init(width: 17, height: 17)
        statusItem.button?.image = image
        return statusItem
    }()

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        // LaunchAtLogin 4 のヘルパー (SMLoginItemSetEnabled) で登録済みの設定を SMAppService に引き継ぐ。呼ばないと更新後に無効扱いになる
        LaunchAtLogin.migrateIfNeeded()
        start()
    }

    private func start() {
        stop()

        setupMenu()

        guard !Settings.isDisabled else { return }

        setupDevice()
        setupDeviceNotifications()
        deviceListObserver = NotificationCenter.default.addObserver(forName: .deviceListChanged,
                                                                    object: nil,
                                                                    queue: .main) { [weak self] _ in
            guard let self else { return }
            currentDevices = simply.allOutputDevices
            setupMenu()
            setupDevice()
            setupDeviceNotifications()
        }
    }

    private func stop() {
        if let observer = deviceListObserver {
            NotificationCenter.default.removeObserver(observer)
            deviceListObserver = nil
        }
        deviceObservers.forEach { NotificationCenter.default.removeObserver($0) }
        deviceObservers = []
    }

    private func setupMenu() {
        let menu = NSMenu()
        let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? ""
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        menu.addItem(makeMenuItem(title: "Disable", selector: #selector(AppDelegate.toggleDisable(_:)), isOn: Settings.isDisabled))
        menu.addItem(.separator())
        menu.addItem(makeMenuItem(title: "Output", selector: nil))
        let anchoredDeviceName = Settings.anchoredDeviceName
        currentDevices.forEach {
            menu.addItem(makeMenuItem(title: $0.name, selector: #selector(AppDelegate.anchor(_:)), isOn: $0.name == anchoredDeviceName))
        }
        menu.addItem(.separator())
        menu.addItem(makeMenuItem(title: "Check for Updates...", selector: #selector(SPUStandardUpdaterController.checkForUpdates(_:)), target: updaterController))
        menu.addItem(.separator())
        menu.addItem(makeMenuItem(title: "Launch at Login", selector: #selector(AppDelegate.toggleLaunchAtLogin(_:)), isOn: Settings.isLaunchAtLoginEnabled))
        menu.addItem(makeMenuItem(title: "About \(name) \(version)", selector: #selector(AppDelegate.openGitHub(_:))))
        menu.addItem(makeMenuItem(title: "Quit", selector: #selector(AppDelegate.quit(_:))))
        statusItem.menu = menu
    }

    private func makeMenuItem(title: String, selector: Selector?, target: AnyObject? = nil, isOn: Bool? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = target
        if let isOn {
            item.state = isOn ? .on : .off
        }
        return item
    }

    private func setupDevice() {
        guard let anchoredDeviceName = Settings.anchoredDeviceName else { return }
        guard let anchoredDevice = currentDevices.first(where: { $0.name == anchoredDeviceName }) else {
            connectBluetoothDevice(named: anchoredDeviceName)
            return
        }
        anchoredDevice.isDefaultOutputDevice = true
        anchoredDevice.isDefaultSystemOutputDevice = true
    }

    /**
     ケースから出した AirPods が iPhone 側につながっていると、Mac の出力先に現れず固定できない。
     ペアリング済みなら Mac から接続を要求し、出力先に現れた時点で deviceListChanged から固定する
     */
    private func connectBluetoothDevice(named name: String) {
        guard
            connectingDevice == nil,
            let device = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice])?.first(where: { $0.name == name }),
            !device.isConnected()
        else { return }
        // target を渡すと非同期になり、メインスレッドを止めない。結果は connectionComplete(_:status:) に届く
        guard device.openConnection(self) == kIOReturnSuccess else { return }
        connectingDevice = device
    }

    @objc private func connectionComplete(_ device: IOBluetoothDevice, status: IOReturn) {
        connectingDevice = nil
    }

    private func setupDeviceNotifications() {
        deviceObservers.forEach { NotificationCenter.default.removeObserver($0) }
        let anchoredDeviceName = Settings.anchoredDeviceName
        deviceObservers = currentDevices.compactMap {
            guard $0.name != anchoredDeviceName else { return nil }
            return NotificationCenter.default.addObserver(forName: .deviceIsRunningSomewhereDidChange, object: $0, queue: .main) { [weak self] _ in
                guard let self else { return }
                setupDevice()
            }
        }
    }

    @objc private func toggleDisable(_ sender: NSMenuItem) {
        Settings.isDisabled.toggle()
        Settings.isDisabled ? stop() : start()
        sender.state = Settings.isDisabled ? .on : .off
    }

    @objc private func anchor(_ sender: NSMenuItem) {
        Settings.anchoredDeviceName = Settings.anchoredDeviceName == sender.title ? nil : sender.title
        // メニューのチェック表示と、固定先以外を監視する deviceObservers を新しい固定先で作り直す
        start()
        guard Settings.isDisabled else { return }
        // Disable 中の start() は出力先を切り替えないが、メニューで選んだ出力先にはその場で切り替える
        setupDevice()
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        Settings.isLaunchAtLoginEnabled.toggle()
        sender.state = Settings.isLaunchAtLoginEnabled ? .on : .off
    }

    @objc private func openGitHub(_ sender: NSMenuItem) {
        NSWorkspace.shared.open(URL(string: "https://github.com/wata/AudioAnchor")!)
    }

    @objc private func quit(_ sender: NSMenuItem) {
        NSApplication.shared.terminate(self)
    }
}
