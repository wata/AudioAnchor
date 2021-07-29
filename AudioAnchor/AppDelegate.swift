//
//  AppDelegate.swift
//  AudioAnchor
//
//  Created by Wataru Nagasawa on 2021/07/30.
//

import Cocoa
import Sparkle
import LaunchAtLogin
import SimplyCoreAudio

@main
class AppDelegate: NSObject, NSApplicationDelegate {
    private let simply = SimplyCoreAudio()
    private var observers = [NSObjectProtocol]()
    private lazy var currentDevices = simply.allOutputDevices
    private lazy var statusItem: NSStatusItem = {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let image = NSImage(named: "Icon")!
        image.size = .init(width: 17, height: 17)
        statusItem.button?.image = image
        return statusItem
    }()

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        setupMenu()
        setupDevice()
        setupDeviceNotifications()
        NotificationCenter.default.addObserver(forName: .deviceListChanged,
                                               object: nil,
                                               queue: .main) { _ in
            self.currentDevices = self.simply.allOutputDevices
            self.setupMenu()
            self.setupDeviceNotifications()
        }
    }

    private func setupMenu() {
        let menu = NSMenu()
        let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? ""
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        menu.addItem(makeMenuItem(title: "\(name) \(version)", selector: #selector(AppDelegate.openGitHub(_:))))
        menu.addItem(makeMenuItem(title: "Check for Updates...", selector: #selector(SUUpdater.checkForUpdates(_:)), target: SUUpdater.shared()))
        menu.addItem(.separator())
        let anchoredDeviceName = UserDefaults.standard.string(forKey: .anchoredDeviceName)
        currentDevices.forEach {
            menu.addItem(makeMenuItem(title: $0.name, selector: #selector(AppDelegate.anchor(_:)), isEnabled: $0.name == anchoredDeviceName))
        }
        menu.addItem(.separator())
        menu.addItem(makeMenuItem(title: "Launch at Login", selector: #selector(AppDelegate.toggleLaunchAtLogin(_:)), isEnabled: LaunchAtLogin.isEnabled))
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
        currentDevices.forEach {
            guard $0.name == UserDefaults.standard.string(forKey: .anchoredDeviceName) else { return }
            $0.isDefaultOutputDevice = true
            $0.isDefaultSystemOutputDevice = true
        }
    }

    private func setupDeviceNotifications() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = currentDevices.compactMap { device in
            guard device.name != UserDefaults.standard.string(forKey: .anchoredDeviceName) else { return nil }
            return NotificationCenter.default.addObserver(forName: .deviceIsRunningSomewhereDidChange, object: device, queue: .main) { _ in
                self.setupDevice()
            }
        }
    }

    @objc private func openGitHub(_ sender: NSButton) {
        NSWorkspace.shared.open(URL(string: "https://github.com/wata/AudioAnchor")!)
    }

    @objc private func anchor(_ sender: NSButton) {
        statusItem.menu?.items.forEach { item in
            guard currentDevices.contains(where: { $0.name == item.title }) else { return }
            item.state = .off
        }
        guard UserDefaults.standard.string(forKey: .anchoredDeviceName) != sender.title else {
            UserDefaults.standard.set(nil, forKey: .anchoredDeviceName)
            return
        }
        UserDefaults.standard.set(sender.title, forKey: .anchoredDeviceName)
        sender.state = .on
        setupDevice()
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSButton) {
        LaunchAtLogin.isEnabled = !LaunchAtLogin.isEnabled
        sender.state = LaunchAtLogin.isEnabled ? .on : .off
    }

    @objc private func quit(_ sender: NSButton) {
        NSApplication.shared.terminate(self)
    }
}

fileprivate extension String {
    static let anchoredDeviceName = "anchoredDeviceName"
}
