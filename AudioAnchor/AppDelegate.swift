//
//  AppDelegate.swift
//  AudioAnchor
//
//  Created by Wataru Nagasawa on 2021/07/30.
//

import Cocoa
import Sparkle
import SimplyCoreAudio

@main
class AppDelegate: NSObject, NSApplicationDelegate {
    private let simply = SimplyCoreAudio()
    private var deviceListObserver: NSObjectProtocol?
    private var deviceObservers = [NSObjectProtocol]()
    private lazy var currentDevices = simply.allOutputDevices
    private lazy var statusItem: NSStatusItem = {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let image = NSImage(named: "Icon")!
        image.size = .init(width: 17, height: 17)
        statusItem.button?.image = image
        return statusItem
    }()

    func applicationDidFinishLaunching(_ aNotification: Notification) {
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
                                                                    queue: .main) { _ in
            self.currentDevices = self.simply.allOutputDevices
            self.setupMenu()
            self.setupDevice()
            self.setupDeviceNotifications()
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
        menu.addItem(makeMenuItem(title: "Disable", selector: #selector(AppDelegate.toggleDisable(_:)), isEnabled: Settings.isDisabled))
        menu.addItem(.separator())
        menu.addItem(makeMenuItem(title: "Output", selector: nil))
        let anchoredDeviceName = Settings.anchoredDeviceName
        currentDevices.forEach {
            menu.addItem(makeMenuItem(title: $0.name, selector: #selector(AppDelegate.anchor(_:)), isEnabled: $0.name == anchoredDeviceName))
        }
        menu.addItem(.separator())
        menu.addItem(makeMenuItem(title: "Check for Updates...", selector: #selector(SUUpdater.checkForUpdates(_:)), target: SUUpdater.shared()))
        menu.addItem(.separator())
        menu.addItem(makeMenuItem(title: "Launch at Login", selector: #selector(AppDelegate.toggleLaunchAtLogin(_:)), isEnabled: Settings.isLaunchAtLoginEnabled))
        menu.addItem(makeMenuItem(title: "About \(name) \(version)", selector: #selector(AppDelegate.openGitHub(_:))))
        menu.addItem(makeMenuItem(title: "Quit", selector: #selector(AppDelegate.quit(_:))))
        statusItem.menu = menu
    }

    private func makeMenuItem(title: String, selector: Selector?, target: AnyObject? = nil, isEnabled: Bool? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        if let target = target {
            item.target = target
        }
        if let isEnabled = isEnabled {
            item.state = isEnabled ? .on : .off
        }
        return item
    }

    private func setupDevice() {
        let anchoredDeviceName = Settings.anchoredDeviceName
        guard let anchoredDevice = currentDevices.first(where: { $0.name == anchoredDeviceName }) else { return }
        anchoredDevice.isDefaultOutputDevice = true
        anchoredDevice.isDefaultSystemOutputDevice = true
    }

    private func setupDeviceNotifications() {
        deviceObservers.forEach { NotificationCenter.default.removeObserver($0) }
        let anchoredDeviceName = Settings.anchoredDeviceName
        deviceObservers = currentDevices.compactMap {
            guard $0.name != anchoredDeviceName else { return nil }
            return NotificationCenter.default.addObserver(forName: .deviceIsRunningSomewhereDidChange, object: $0, queue: .main) { _ in
                self.setupDevice()
            }
        }
    }

    @objc private func toggleDisable(_ sender: NSButton) {
        Settings.isDisabled = !Settings.isDisabled
        Settings.isDisabled ? stop() : start()
        sender.state = Settings.isDisabled ? .on : .off
    }

    @objc private func anchor(_ sender: NSButton) {
        statusItem.menu?.items.forEach { item in
            guard currentDevices.contains(where: { $0.name == item.title }) else { return }
            item.state = .off
        }
        guard Settings.anchoredDeviceName != sender.title else {
            Settings.anchoredDeviceName = nil
            return
        }
        Settings.anchoredDeviceName = sender.title
        sender.state = .on
        setupDevice()
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSButton) {
        Settings.isLaunchAtLoginEnabled = !Settings.isLaunchAtLoginEnabled
        sender.state = Settings.isLaunchAtLoginEnabled ? .on : .off
    }

    @objc private func openGitHub(_ sender: NSButton) {
        NSWorkspace.shared.open(URL(string: "https://github.com/wata/AudioAnchor")!)
    }

    @objc private func quit(_ sender: NSButton) {
        NSApplication.shared.terminate(self)
    }
}
