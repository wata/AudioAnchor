//
//  AppDelegate.swift
//  AudioAnchor
//
//  Created by Wataru Nagasawa on 2021/07/30.
//

import Cocoa
import Sparkle
import IOBluetooth

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    private var deviceListObservation: AudioPropertyObservation?
    private var deviceObservations = [AudioPropertyObservation]()
    // 通知のたびに接続要求を重ねないよう、接続を試している機器を持っておく
    private var connectingDevice: IOBluetoothDevice?
    /**
     AirPods の自動切り替えで iPhone に音声を取られている間も Bluetooth 接続は残り、Core Audio のデバイス一覧は変化しない。
     固定先が使えない状態の表示を更新するため、Bluetooth の接続・切断を監視する
     */
    private var bluetoothConnectNotification: IOBluetoothUserNotification?
    private var bluetoothDisconnectNotifications = [IOBluetoothUserNotification]()
    private var currentDevices = [AudioOutputDevice]()
    private lazy var statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private lazy var icon: NSImage = {
        let image = NSImage(named: "Icon")!
        image.size = StatusIcon.size
        return image
    }()
    private lazy var badgedIcon = icon.badged()
    private weak var warningItem: NSMenuItem?

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        // LaunchAtLogin パッケージ 4 以前のヘルパー (SMLoginItemSetEnabled) で登録済みの設定を SMAppService に引き継ぐ。呼ばないと更新後に無効扱いになる
        Settings.migrateLaunchAtLoginIfNeeded()
        start()
    }

    private func start() {
        stop()

        // Disable 中はデバイス一覧の変化を監視していないため、始めるたびに取り直す
        currentDevices = AudioOutputDevice.all
        setupMenu()

        guard !Settings.isDisabled else { return }

        setupDevice()
        setupDeviceNotifications()
        deviceListObservation = AudioOutputDevice.observeDeviceList { [weak self] in
            guard let self else { return }
            currentDevices = AudioOutputDevice.all
            setupMenu()
            setupDevice()
            setupDeviceNotifications()
        }
        bluetoothConnectNotification = IOBluetoothDevice.register(forConnectNotifications: self, selector: #selector(bluetoothDeviceConnected(_:device:)))
    }

    private func stop() {
        deviceListObservation = nil
        deviceObservations = []
        // IOBluetoothUserNotification は解放しても解除されないため、明示的に解除する
        bluetoothConnectNotification?.unregister()
        bluetoothConnectNotification = nil
        bluetoothDisconnectNotifications.forEach { $0.unregister() }
        bluetoothDisconnectNotifications = []
    }

    /**
     Bluetooth では Mac につながっているのに Core Audio の出力先に現れないときは、iPhone などに AirPods を奪われている。
     Mac が音声を使っていなければ、Mac で再生を始めたときに macOS が AirPods を取り戻すので警告しない。
     他の出力先を使っているアプリがあると macOS は取り戻しを飛ばし (ログの "PredictiveRoute: Skip, Mac is not idle")、
     公開 API では経路を取り戻せないため、ユーザーに知らせる
     */
    private var isAnchoredDeviceUnavailable: Bool {
        guard
            !Settings.isDisabled,
            let anchoredDeviceName = Settings.anchoredDeviceName,
            !currentDevices.contains(where: { $0.name == anchoredDeviceName }),
            currentDevices.contains(where: { $0.isRunningSomewhere })
        else {
            return false
        }
        // 同じ名前のペアリング済み機器が複数あることがあるため、どれか1つでも接続していれば対象とみなす
        let devices = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []
        return devices.contains { $0.displayName == anchoredDeviceName && $0.isConnected() }
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
        let isUnavailable = isAnchoredDeviceUnavailable
        if
            isUnavailable,
            let anchoredDeviceName
        {
            // 出力先の行と同じ見た目にすると使えるように見えてしまうため、固定先は行にせず説明の中で名前を出す
            let item = makeMenuItem(title: "", selector: nil)
            updateWarning(item, anchoredDeviceName: anchoredDeviceName)
            menu.addItem(item)
            warningItem = item
        }
        menu.addItem(.separator())
        menu.addItem(makeMenuItem(title: "Check for Updates...", selector: #selector(SPUStandardUpdaterController.checkForUpdates(_:)), target: updaterController))
        menu.addItem(.separator())
        menu.addItem(makeMenuItem(title: "Launch at Login", selector: #selector(AppDelegate.toggleLaunchAtLogin(_:)), isOn: Settings.isLaunchAtLoginEnabled))
        menu.addItem(makeMenuItem(title: "About \(name) \(version)", selector: #selector(AppDelegate.openGitHub(_:))))
        menu.addItem(makeMenuItem(title: "Quit", selector: #selector(AppDelegate.quit(_:))))
        menu.delegate = self
        statusItem.menu = menu
        // メニューを開かなくても気づけるよう、固定先が使えない間はアイコンにバッジを付ける
        statusItem.button?.image = isUnavailable ? badgedIcon : icon
    }

    /**
     音を出していないアプリでも出力を開いていれば macOS は AirPods を取り戻さないため、そのアプリを名指しして閉じる手がかりにする。
     メニューの幅を広げないよう、行には原因だけを出し、操作方法はツールチップに回す。
     ヘルパープロセスなどで同じ名前が並ばないよう、重複は除く。
     通知音を鳴らす systemsoundserverd など root のプロセスは名前を取れず、鳴らすのも一瞬なので除く
     */
    private func updateWarning(_ item: NSMenuItem, anchoredDeviceName: String) {
        var names = [String]()
        for name in AudioProcess.runningOutput.map(\.name) where !name.isEmpty && !names.contains(name) {
            names.append(name)
        }
        if names.isEmpty {
            item.title = "⚠️ \(anchoredDeviceName) is unavailable"
            item.toolTip = "Select \(anchoredDeviceName) in Control Center > Sound."
        } else {
            item.title = "⚠️ \(names.joined(separator: ", ")) is blocking \(anchoredDeviceName)"
            item.toolTip = "Quit it or select \(anchoredDeviceName) in Control Center > Sound."
        }
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
        anchoredDevice.setAsDefaultOutput()
    }

    /**
     ケースから出した AirPods が iPhone 側につながっていると、Mac の出力先に現れず固定できない。
     ペアリング済みなら Mac から接続を要求し、出力先に現れた時点でデバイス一覧の変化を受けて固定する
     */
    private func connectBluetoothDevice(named name: String) {
        guard
            connectingDevice == nil,
            let device = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice])?.first(where: { $0.displayName == name }),
            !device.isConnected()
        else {
            return
        }
        // target を渡すと非同期になり、メインスレッドを止めない。結果は connectionComplete(_:status:) に届く
        guard device.openConnection(self) == kIOReturnSuccess else { return }
        connectingDevice = device
    }

    @objc private func connectionComplete(_ device: IOBluetoothDevice, status: IOReturn) {
        connectingDevice = nil
    }

    /**
     切断通知は機器ごとにしか登録できないため、接続を受けるたびに登録する。
     登録時点で接続済みの機器の通知はメインスレッドに届くが、その後の接続は IOBluetooth 内部のキューから届き、
     そのままメニューを更新するとクラッシュするため、メインスレッドに移してから処理する
     */
    @objc private func bluetoothDeviceConnected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let disconnectNotification = device.register(forDisconnectNotification: self, selector: #selector(bluetoothDeviceDisconnected(_:device:))) {
                bluetoothDisconnectNotifications.append(disconnectNotification)
            }
            setupMenu()
            setupDevice()
        }
    }

    // 接続通知と同じく、IOBluetooth 内部のキューから届くことがあるため、メインスレッドに移す
    @objc private func bluetoothDeviceDisconnected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            notification.unregister()
            bluetoothDisconnectNotifications.removeAll { $0 === notification }
            setupMenu()
            setupDevice()
        }
    }

    private func setupDeviceNotifications() {
        let anchoredDeviceName = Settings.anchoredDeviceName
        deviceObservations = currentDevices.compactMap {
            guard $0.name != anchoredDeviceName else {
                return nil
            }
            return $0.observeIsRunningSomewhere { [weak self] in
                guard let self else { return }
                // 再生の開始・停止で警告の表示も変わるため、メニューとアイコンも作り直す
                setupMenu()
                setupDevice()
            }
        }
    }

    @objc private func toggleDisable(_ sender: NSMenuItem) {
        Settings.isDisabled.toggle()
        // Disable 中の start() は監視を止めてメニューを作り直すだけなので、チェック表示とアイコンのバッジも揃う
        start()
    }

    @objc private func anchor(_ sender: NSMenuItem) {
        Settings.anchoredDeviceName = Settings.anchoredDeviceName == sender.title ? nil : sender.title
        // メニューのチェック表示と、固定先以外を監視する deviceObservations を新しい固定先で作り直す
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

extension AppDelegate: NSMenuDelegate {
    /// 出力デバイスを使うアプリが入れ替わっても使用中のままなら setupMenu() は呼ばれないため、開くたびに警告のアプリ名を取り直す
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard
            let warningItem,
            let anchoredDeviceName = Settings.anchoredDeviceName
        else {
            return
        }
        updateWarning(warningItem, anchoredDeviceName: anchoredDeviceName)
    }
}

private enum StatusIcon {
    static let size = NSSize(width: 17, height: 17)
    static let badgePointSize: CGFloat = 8
    static let badgeCutoutWidth: CGFloat = 1.5
}

private extension NSImage {
    /**
     メニューバーの明暗に合わせて色が変わるよう、バッジ付きでも template のまま保つ。
     バッジの周りを切り抜くのは、錨の線と重なってもバッジの形が読めるようにするため
     */
    func badged() -> NSImage {
        let badge = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)!
            .withSymbolConfiguration(.init(pointSize: StatusIcon.badgePointSize, weight: .bold))!
        let image = NSImage(size: size, flipped: false) { [self] rect in
            draw(in: rect)
            let badgeRect = NSRect(
                x: rect.maxX - badge.size.width,
                y: rect.minY,
                width: badge.size.width,
                height: badge.size.height
            )
            let cutoutRect = badgeRect.insetBy(dx: -StatusIcon.badgeCutoutWidth, dy: -StatusIcon.badgeCutoutWidth)
            badge.draw(in: cutoutRect, from: .zero, operation: .destinationOut, fraction: 1)
            badge.draw(in: badgeRect)
            return true
        }
        image.isTemplate = true
        return image
    }
}

private extension IOBluetoothDevice {
    /**
     name は工場出荷時の名前 ("AirPods Pro" など) を返し、Core Audio が使うユーザー設定の名前と一致しない。
     ユーザー設定の名前を返す getDisplayName は非公開 API のため、使えないときは name に戻す
     */
    var displayName: String? {
        let selector = NSSelectorFromString("getDisplayName")
        guard responds(to: selector) else {
            return name
        }
        return perform(selector)?.takeUnretainedValue() as? String ?? name
    }
}
