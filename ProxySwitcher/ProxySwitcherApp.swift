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
    var pathMonitor: NWPathMonitor?

    private var vpnLikelyActive: Bool = false {
        didSet {
            DispatchQueue.main.async {
                self.updateStatusIcon()
            }
        }
    }

    private var lastKnownProxyEnabled: Bool = false

    func applicationDidFinishLaunching(_: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            updateStatusIcon()
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        proxyMonitor = ProxyMonitor { [weak self] in
            DispatchQueue.main.async {
                self?.updateStatusIcon()
            }
        }
        proxyMonitor?.startMonitoring()

        let monitor = NWPathMonitor()
        pathMonitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            var hasOther = false
            for iface in path.availableInterfaces {
                if iface.type == .other {
                    hasOther = true
                    break
                }
            }
            self?.vpnLikelyActive = (path.status == .satisfied && hasOther)
        }
        let queue = DispatchQueue(label: "nwpath.monitor.queue")
        monitor.start(queue: queue)
    }

    @objc
    func statusItemClicked(_: NSStatusBarButton) {
        let event = NSApp.currentEvent!

        if event.type == .rightMouseUp {
            showMenu()
        } else {
            toggleProxy()
        }
    }

    func updateStatusIcon() {
        guard let button = statusItem?.button else {
            return
        }

        let proxyEnabled = ProxyManager.shared.isProxyEnabled()

        if vpnLikelyActive {
            let iconName = lastKnownProxyEnabled ? "shield.fill" : "shield"
            button.image = NSImage(systemSymbolName: iconName, accessibilityDescription: nil)
            button.toolTip = "VPN detected. Proxy configuration can be changed only with VPN disabled."
            return
        }

        lastKnownProxyEnabled = proxyEnabled

        let iconName = proxyEnabled ? "network.slash" : "network"
        button.image = NSImage(systemSymbolName: iconName, accessibilityDescription: nil)
        button.toolTip = proxyEnabled ? "Proxy enabled" : "Proxy disabled"
    }

    func toggleProxy() {
        if vpnLikelyActive {
            print("VPN is active. Skipping proxy changes. Disable VPN client to apply changes.")
            updateStatusIcon()
            return
        }

        ProxyManager.shared.toggleProxy()
        updateStatusIcon()
    }

    func showMenu() {
        let menu = NSMenu()

        let vpnTitle = vpnLikelyActive ? "VPN: Active" : "VPN: Inactive"
        let vpnItem = NSMenuItem(title: vpnTitle, action: nil, keyEquivalent: "")
        vpnItem.isEnabled = false
        menu.addItem(vpnItem)

        if vpnLikelyActive {
            let warn = NSMenuItem(title: "On active VPN proxy settings do not apply.", action: nil, keyEquivalent: "")
            warn.isEnabled = false
            menu.addItem(warn)

            let advise = NSMenuItem(title: "To apply proxy changes, disable VPN.", action: nil, keyEquivalent: "")
            advise.isEnabled = false
            menu.addItem(advise)

            menu.addItem(NSMenuItem.separator())
        } else {
            menu.addItem(NSMenuItem.separator())

            let proxyItems = ProxyManager.shared.getProxyInfo()
            if proxyItems.isEmpty {
                let infoItem = NSMenuItem(title: "Proxy is disabled (global)", action: nil, keyEquivalent: "")
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
        }

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
        var items: [String] = []

        if let proxies = SCDynamicStoreCopyProxies(nil) as? [String: Any] {
            let httpEnabled = proxies[kSCPropNetProxiesHTTPEnable as String] as? Int == 1
            let httpsEnabled = proxies[kSCPropNetProxiesHTTPSEnable as String] as? Int == 1

            if httpEnabled {
                if let host = proxies[kSCPropNetProxiesHTTPProxy as String] as? String,
                   let port = proxies[kSCPropNetProxiesHTTPPort as String] as? Int,
                   !host.isEmpty, port > 0 {
                    items.append("global http: \(host):\(port)")
                } else {
                    items.append("global http: enabled (no host/port)")
                }
            }

            if httpsEnabled {
                if let host = proxies[kSCPropNetProxiesHTTPSProxy as String] as? String,
                   let port = proxies[kSCPropNetProxiesHTTPSPort as String] as? Int,
                   !host.isEmpty, port > 0 {
                    items.append("global https: \(host):\(port)")
                } else {
                    items.append("global https: enabled (no host/port)")
                }
            }
        }

        if let auth = obtainAuthorization(interactive: false),
           let preferences = SCPreferencesCreateWithAuthorization(nil, "ProxyToggleRead" as CFString, nil, auth),
           let allServices = SCNetworkServiceCopyAll(preferences) as? [SCNetworkService] {
            let services = allServices.filter { service in
                guard let iface = SCNetworkServiceGetInterface(service) else {
                    return false
                }
                let enabled = SCNetworkServiceGetEnabled(service)
                let bsdName = SCNetworkInterfaceGetBSDName(iface) as String? ?? ""
                return enabled && !bsdName.isEmpty
            }

            for service in services {
                if let iface = SCNetworkServiceGetInterface(service) {
                    let bsdName = SCNetworkInterfaceGetBSDName(iface) as String? ?? "iface"
                    if let protocolConfig = SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeProxies),
                       let proxyConfig = SCNetworkProtocolGetConfiguration(protocolConfig) as? [String: Any] {
                        let httpEnabled = proxyConfig[kSCPropNetProxiesHTTPEnable as String] as? Int == 1
                        let httpsEnabled = proxyConfig[kSCPropNetProxiesHTTPSEnable as String] as? Int == 1

                        if httpEnabled {
                            let host = proxyConfig[kSCPropNetProxiesHTTPProxy as String] as? String ?? ""
                            let port = proxyConfig[kSCPropNetProxiesHTTPPort as String] as? Int ?? 0
                            if !host.isEmpty, port > 0 {
                                items.append("\(bsdName) http: \(host):\(port)")
                            } else {
                                items.append("\(bsdName) http: enabled (no host/port)")
                            }
                        }
                        if httpsEnabled {
                            let host = proxyConfig[kSCPropNetProxiesHTTPSProxy as String] as? String ?? ""
                            let port = proxyConfig[kSCPropNetProxiesHTTPSPort as String] as? Int ?? 0
                            if !host.isEmpty, port > 0 {
                                items.append("\(bsdName) https: \(host):\(port)")
                            } else {
                                items.append("\(bsdName) https: enabled (no host/port)")
                            }
                        }
                    }
                }
            }
        }

        return items
    }

    func toggleProxy() {
        let currentEnabled = isProxyEnabled()

        guard let authRef = obtainAuthorization(interactive: true) else {
            print("Authorization not granted. Aborting toggle.")
            return
        }

        guard let preferences = SCPreferencesCreateWithAuthorization(nil, "ProxyToggle" as CFString, nil, authRef) else {
            print("SCPreferencesCreateWithAuthorization failed")
            return
        }

        guard let allServices = SCNetworkServiceCopyAll(preferences) as? [SCNetworkService] else {
            print("Failed to access network services")
            return
        }

        let services = allServices.filter { service in
            guard let iface = SCNetworkServiceGetInterface(service) else {
                return false
            }
            let bsdName = SCNetworkInterfaceGetBSDName(iface) as String? ?? ""
            return SCNetworkServiceGetEnabled(service) && !bsdName.isEmpty
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

        let keys = [
            "State:/Network/Global/Proxies",
            "State:/Network/Global/IPv4",
            "State:/Network/Global/IPv6",
            "State:/Network/Global/DNS"
        ] as CFArray

        let patterns = [
            "State:/Network/Service/.*/Proxies",
            "Setup:/Network/Service/.*/Proxies"
        ] as CFArray

        SCDynamicStoreSetNotificationKeys(store, keys, patterns)

        let runLoopSource = SCDynamicStoreCreateRunLoopSource(nil, store, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .defaultMode)
    }
}
