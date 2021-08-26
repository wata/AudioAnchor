//
//  Settings.swift
//  AudioAnchor
//
//  Created by Wataru Nagasawa on 2021/09/07.
//

import Foundation
import LaunchAtLogin

struct Settings {
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
            LaunchAtLogin.isEnabled
        }
        set {
            LaunchAtLogin.isEnabled = newValue
        }
    }

    static var anchoredDeviceName: String? {
        get {
            UserDefaults.standard.string(forKey: .anchoredDeviceName)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: .anchoredDeviceName)
        }
    }
}

fileprivate extension String {
    static let isDisabled = "isDisabled"
    static let anchoredDeviceName = "anchoredDeviceName"
}
