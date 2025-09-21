import CoreFoundation
import Foundation
import Network
import Security
import SwiftUI
import SystemConfiguration

// MARK: - ProxyToggleApp

@main
struct ProxyToggleApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self)
    var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

// MARK: - AppDelegate

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    var proxyMonitor: ProxyMonitor?

    func applicationDidFinishLaunching(_: Notification) {
        // Убираем иконку из Дока и Cmd-Tab (альтернатива — LSUIElement=YES в Info.plist)
        NSApp.setActivationPolicy(.accessory)

        // Создаем элемент в строке меню
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            updateStatusIcon()
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        // Запускаем мониторинг изменений прокси
        proxyMonitor = ProxyMonitor { [weak self] in
            DispatchQueue.main.async {
                self?.updateStatusIcon()
            }
        }
        proxyMonitor?.startMonitoring()
    }

    @objc
    func statusItemClicked(_: NSStatusBarButton) {
        let event = NSApp.currentEvent!

        if event.type == .rightMouseUp {
            // Правый клик - показываем меню
            showMenu()
        } else {
            // Левый клик - переключаем прокси
            toggleProxy()
        }
    }

    func updateStatusIcon() {
        guard let button = statusItem?.button else {
            return
        }

        let proxyEnabled = ProxyManager.shared.isProxyEnabled()
        let iconName = proxyEnabled ? "network" : "network.slash"
        button.image = NSImage(systemSymbolName: iconName, accessibilityDescription: nil)
    }

    func toggleProxy() {
        ProxyManager.shared.toggleProxy()
        updateStatusIcon()
    }

    func showMenu() {
        let menu = NSMenu()

        let proxyItems = ProxyManager.shared.getProxyInfo()
        if proxyItems.isEmpty {
            let infoItem = NSMenuItem(title: "Proxy is disabled", action: nil, keyEquivalent: "")
            infoItem.isEnabled = false
            menu.addItem(infoItem)
        } else {
            for item in proxyItems {
                let infoItem = NSMenuItem(title: item, action: nil, keyEquivalent: "")
                infoItem.isEnabled = false
                menu.addItem(infoItem)
            }
        }

        menu.addItem(NSMenuItem.separator())

        // Кнопка выхода
        let quitItem = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil
    }

    @objc
    func quitApp() {
        NSApplication.shared.terminate(nil)
    }
}

// MARK: - ProxyManager

class ProxyManager {
    static let shared = ProxyManager()
    private init() {}

    private var authorizationRef: AuthorizationRef?

    private var isSandboxed: Bool {
        ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
    }

    private func obtainAuthorization(interactive: Bool = true) -> AuthorizationRef? {
        if isSandboxed {
            print("App Sandbox appears to be enabled. Disable App Sandbox in the target's Signing & Capabilities to modify system network settings.")
        }

        if let auth = authorizationRef {
            return auth
        }

        var authRef: AuthorizationRef?
        let createStatus = AuthorizationCreate(nil, nil, [], &authRef)
        if createStatus != errAuthorizationSuccess {
            print("AuthorizationCreate failed: \(createStatus)")
            return nil
        }

        var emptyRights = AuthorizationRights(count: 0, items: nil)
        var flags: AuthorizationFlags = [.extendRights, .preAuthorize]
        if interactive {
            flags.insert(.interactionAllowed)
        }

        let copyStatus = AuthorizationCopyRights(authRef!, &emptyRights, nil, flags, nil)
        if copyStatus != errAuthorizationSuccess {
            print("AuthorizationCopyRights (empty rights) failed: \(copyStatus)")
            AuthorizationFree(authRef!, [])
            return nil
        }

        authorizationRef = authRef
        return authRef
    }

    func isProxyEnabled() -> Bool {
        guard let proxies = SCDynamicStoreCopyProxies(nil) as? [String: Any] else {
            return false
        }

        let httpEnabled = proxies[kSCPropNetProxiesHTTPEnable as String] as? Int == 1
        let httpsEnabled = proxies[kSCPropNetProxiesHTTPSEnable as String] as? Int == 1

        return httpEnabled || httpsEnabled
    }

    func getProxyInfo() -> [String] {
        guard let proxies = SCDynamicStoreCopyProxies(nil) as? [String: Any] else {
            return []
        }

        var items: [String] = []

        let httpEnabled = proxies[kSCPropNetProxiesHTTPEnable as String] as? Int == 1
        if httpEnabled {
            if let host = proxies[kSCPropNetProxiesHTTPProxy as String] as? String,
               let port = proxies[kSCPropNetProxiesHTTPPort as String] as? Int,
               !host.isEmpty, port > 0 {
                items.append("http: \(host):\(port)")
            }
        }

        let httpsEnabled = proxies[kSCPropNetProxiesHTTPSEnable as String] as? Int == 1
        if httpsEnabled {
            if let host = proxies[kSCPropNetProxiesHTTPSProxy as String] as? String,
               let port = proxies[kSCPropNetProxiesHTTPSPort as String] as? Int,
               !host.isEmpty, port > 0 {
                items.append("https: \(host):\(port)")
            }
        }

        return items
    }

    func toggleProxy() {
        let currentEnabled = isProxyEnabled()

        // Получаем/запрашиваем права
        guard let authRef = obtainAuthorization(interactive: true) else {
            print("Authorization not granted. Aborting toggle.")
            return
        }

        // Создаем SCPreferences с авторизацией
        guard let preferences = SCPreferencesCreateWithAuthorization(nil, "ProxyToggle" as CFString, nil, authRef) else {
            print("SCPreferencesCreateWithAuthorization failed")
            return
        }

        guard let allServices = SCNetworkServiceCopyAll(preferences) as? [SCNetworkService] else {
            print("Failed to access network services")
            return
        }

        // Фильтруем только активные сервисы с интерфейсом (Wi‑Fi/Еthernet)
        let services = allServices.filter { service in
            guard SCNetworkServiceGetInterface(service) != nil else {
                return false
            }
            return SCNetworkServiceGetEnabled(service)
        }

        var anyChange = false

        for service in services {
            guard let protocolConfig = SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeProxies) else {
                continue
            }

            guard let proxyConfig = SCNetworkProtocolGetConfiguration(protocolConfig) else {
                continue
            }

            guard let mutableConfig = (proxyConfig as NSDictionary).mutableCopy() as? NSMutableDictionary else {
                continue
            }

            // Включаем/выключаем флаги независимо от наличия значений хоста/порта.
            // Предполагаем, что host/port уже заданы в системе пользователем.
            mutableConfig[kSCPropNetProxiesHTTPEnable as String] = currentEnabled ? 0 : 1
            mutableConfig[kSCPropNetProxiesHTTPSEnable as String] = currentEnabled ? 0 : 1

            if !SCNetworkProtocolSetConfiguration(protocolConfig, mutableConfig) {
                let err = SCError()
                print("SCNetworkProtocolSetConfiguration failed with error: \(err)")
            } else {
                anyChange = true
            }
        }

        if anyChange {
            if !SCPreferencesCommitChanges(preferences) {
                let err = SCError()
                print("SCPreferencesCommitChanges failed with error: \(err)")
                if err == 1_003 {
                    print("Access error (1003). Ensure App Sandbox is disabled and try launching the app outside of Xcode if the auth dialog doesn’t appear.")
                }
            }
            if !SCPreferencesApplyChanges(preferences) {
                let err = SCError()
                print("SCPreferencesApplyChanges failed with error: \(err)")
                if err == 1_003 {
                    print("Access error (1003). Ensure App Sandbox is disabled and try launching the app outside of Xcode if the auth dialog doesn’t appear.")
                }
            }
        } else {
            print("No proxy configuration changes were applied to any active service.")
        }
    }
}

// MARK: - ProxyMonitor

class ProxyMonitor {
    private var dynamicStore: SCDynamicStore?
    private let callback: () -> Void

    init(callback: @escaping () -> Void) {
        self.callback = callback
    }

    func startMonitoring() {
        var context = SCDynamicStoreContext(
            version: 0,
            info: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        dynamicStore = SCDynamicStoreCreate(
            nil,
            "ProxyToggle" as CFString,
            { _, _, info in
                if let info {
                    let monitor = Unmanaged<ProxyMonitor>.fromOpaque(info).takeUnretainedValue()
                    monitor.callback()
                }
            },
            &context
        )

        guard let store = dynamicStore else {
            return
        }

        let keys = ["State:/Network/Global/Proxies"] as CFArray
        SCDynamicStoreSetNotificationKeys(store, keys, nil)

        let runLoopSource = SCDynamicStoreCreateRunLoopSource(nil, store, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .defaultMode)
    }
}
