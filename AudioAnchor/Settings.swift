//
//  Settings.swift
//  AudioAnchor
//
//  Created by Wataru Nagasawa on 2021/09/07.
//

import Foundation
import os
import ServiceManagement

enum Settings {
    static var isDisabled: Bool {
        get {
            UserDefaults.standard.bool(forKey: .isDisabled)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: .isDisabled)
        }
    }

    static var isLaunchAtLoginEnabled: Bool {
        get {
            SMAppService.mainApp.status == .enabled
        }
        set {
            do {
                if newValue {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                Logger.app.error("Failed to update login item: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /**
     LaunchAtLogin パッケージ 4 以前のヘルパー (SMLoginItemSetEnabled) で登録された設定を SMAppService に引き継ぎ、ヘルパーを解除する。
     パッケージの migrateIfNeeded() で移行済みのユーザーを二重に移行しないよう、同じ UserDefaults キーを使う
     */
    static func migrateLaunchAtLoginIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: .hasMigratedLaunchAtLogin) else { return }
        UserDefaults.standard.set(true, forKey: .hasMigratedLaunchAtLogin)

        let legacy = Settings.self as LegacyLaunchAtLogin.Type
        let helperID = "\(Bundle.main.bundleIdentifier!)-LaunchAtLoginHelper"
        let job = legacy.jobDictionaries?.first { ($0["Label"] as? String) == helperID }
        if job?["OnDemand"] as? Bool ?? false {
            isLaunchAtLoginEnabled = true
        }
        legacy.disableLoginItem(helperID)
        try? SMAppService.loginItem(identifier: helperID).unregister()
    }

    static func anchoredDeviceName(for direction: AudioDirection) -> String? {
        UserDefaults.standard.string(forKey: .anchoredDeviceName(for: direction))
    }

    static func setAnchoredDeviceName(_ name: String?, for direction: AudioDirection) {
        UserDefaults.standard.set(name, forKey: .anchoredDeviceName(for: direction))
    }
}

fileprivate extension String {
    static let isDisabled = "isDisabled"
    static let hasMigratedLaunchAtLogin = "LaunchAtLogin__hasMigrated"

    /// 入力の固定を足す前から出力の固定先を保存しているキーは、更新しても固定先が外れないようそのまま使う
    static func anchoredDeviceName(for direction: AudioDirection) -> String {
        switch direction {
        case .output: "anchoredDeviceName"
        case .input: "anchoredInputDeviceName"
        }
    }
}

/**
 旧ヘルパーの判定と解除には deprecated な API しかない。
 deprecated 指定のメンバーを protocol 経由で呼ぶと警告が出ないことを利用して、ビルド警告を抑える
 */
private protocol LegacyLaunchAtLogin {
    static var jobDictionaries: [[String: AnyObject]]? { get }
    static func disableLoginItem(_ identifier: String)
}

extension Settings: LegacyLaunchAtLogin {
    @available(*, deprecated)
    fileprivate static var jobDictionaries: [[String: AnyObject]]? {
        SMCopyAllJobDictionaries(kSMDomainUserLaunchd)?.takeRetainedValue() as? [[String: AnyObject]]
    }

    @available(*, deprecated)
    fileprivate static func disableLoginItem(_ identifier: String) {
        SMLoginItemSetEnabled(identifier as CFString, false)
    }
}
