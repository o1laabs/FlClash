import Foundation
import Flutter
import NetworkExtension
import UIKit

/// Bridges FlClash's `${packageName}/service`, `${packageName}/core`, and `${packageName}/app`
/// MethodChannels on iOS & iPadOS.
///
/// Automatically supports two execution modes:
/// 1. **In-Process Proxy Mode (Free Apple ID Default)**:
///    When signed with a personal free Apple ID (no NetworkExtension entitlement), runs `Core.xcframework`
///    directly inside the main `Runner` process, starts local Mixed HTTP/SOCKS5 proxy + PAC helper server,
///    and activates silent audio keep-alive so iOS does not suspend the core in the background.
/// 2. **System-Wide TUN Mode (`NEPacketTunnelProvider`)**:
///    When signed with TrollStore or a paid developer certificate containing `packet-tunnel-provider`,
///    manages `NEunnelProviderManager` and forwards RPC calls to the `PacketTunnel` extension via IPC.
final class FlClashServicePlugin: NSObject {
    static let packageName = "com.follow.clash"
    static let appGroupId = "group.com.follow.clash.ios"

    private let messenger: FlutterBinaryMessenger
    private let serviceChannel: FlutterMethodChannel
    private let coreChannel: FlutterMethodChannel
    private let appChannel: FlutterMethodChannel
    private let coreQueue = DispatchQueue(label: "com.follow.clash.ios.core", qos: .userInitiated)

    private var tunnelManager: NETunnelProviderManager?
    private var isRunningInProcess = false
    private var isCoreStarted = false
    private let keepAliveManager = BackgroundKeepAliveManager()
    private let pacServer = LocalPACServer()

    init(messenger: FlutterBinaryMessenger) {
        self.messenger = messenger
        self.serviceChannel = FlutterMethodChannel(
            name: "\(Self.packageName)/service",
            binaryMessenger: messenger
        )
        self.coreChannel = FlutterMethodChannel(
            name: "\(Self.packageName)/core",
            binaryMessenger: messenger
        )
        self.appChannel = FlutterMethodChannel(
            name: "\(Self.packageName)/app",
            binaryMessenger: messenger
        )
        super.init()
    }

    func register() {
        serviceChannel.setMethodCallHandler { [weak self] call, result in
            self?.handleServiceCall(call: call, result: result)
        }
        coreChannel.setMethodCallHandler { [weak self] call, result in
            self?.handleCoreCall(call: call, result: result)
        }
        appChannel.setMethodCallHandler { [weak self] call, result in
            self?.handleAppCall(call: call, result: result)
        }
        observeVPNStatus()
    }

    /// Resolves the shared directory path. If App Group is available (Paid Cert / TrollStore),
    /// uses the shared container; otherwise (Free Apple ID), gracefully falls back to Application Support.
    func resolveSharedWorkingDirectory() -> URL {
        if let groupURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: Self.appGroupId
        ) {
            return groupURL
        }
        let fallback = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        try? FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true)
        return fallback
    }

    // MARK: - `${packageName}/service` Handler
    private func handleServiceCall(call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "init":
            coreQueue.async {
                MobileInitIOSMemoryLimit(false)
                MobileSetIOSEventListener(IOSEventBridge { [weak self] eventJson in
                    DispatchQueue.main.async {
                        self?.serviceChannel.invokeMethod("onEvent", arguments: eventJson)
                    }
                })
                result(true)
            }

        case "startVpn", "startService", "start":
            let args = call.arguments as? [String: Any] ?? [:]
            startProxyService(options: args, result: result)

        case "stopVpn", "stopService", "stop":
            stopProxyService(result: result)

        case "getSharedDirPath":
            result(resolveSharedWorkingDirectory().path)

        case "getRunMode":
            result(isRunningInProcess ? "in_process_free_account" : "packet_tunnel_extension")

        default:
            result(true)
        }
    }

    // MARK: - `${packageName}/core` Handler
    private func handleCoreCall(call: FlutterMethodCall, result: @escaping FlutterResult) {
        // Core calls are dispatched on a serial background queue as required by FlClash's architecture.md
        coreQueue.async { [weak self] in
            guard let self = self else { return }
            let payload: String
            if let str = call.arguments as? String {
                payload = str
            } else if let dict = call.arguments as? [String: Any],
                      let data = try? JSONSerialization.data(withJSONObject: dict),
                      let encoded = String(data: data, encoding: .utf8) {
                payload = encoded
            } else {
                let envelope: [String: Any] = [
                    "id": UUID().uuidString,
                    "method": call.method,
                    "params": call.arguments ?? NSNull()
                ]
                let data = (try? JSONSerialization.data(withJSONObject: envelope)) ?? Data()
                payload = String(data: data, encoding: .utf8) ?? "{}"
            }

            if !self.isRunningInProcess,
               let session = self.tunnelManager?.connection as? NETunnelProviderSession,
               session.status == .connected,
               let msgData = payload.data(using: .utf8) {
                do {
                    try session.sendProviderMessage(msgData) { responseData in
                        let responseStr = responseData.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                        result(responseStr)
                    }
                    return
                } catch {
                    // Fall through to in-process invocation if extension IPC fails
                }
            }

            let responseJson = MobileInvokeCoreMethod(payload)
            result(responseJson)
        }
    }

    // MARK: - `${packageName}/app` Handler
    private func handleAppCall(call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "getSharedDirectory":
            result(resolveSharedWorkingDirectory().path)
        case "moveTaskToBack":
            result(true)
        case "updateExcludeFromRecents":
            result(true)
        case "openSystemProxyGuide":
            // Opens local HTTP server hosting a 1-tap Wi-Fi Proxy .mobileconfig for Free Apple ID users
            let urlStr = "http://127.0.0.1:\(pacServer.port)/proxy.mobileconfig"
            if let url = URL(string: urlStr) {
                UIApplication.shared.open(url, options: [:]) { ok in
                    result(ok)
                }
            } else {
                result(false)
            }
        default:
            result(nil)
        }
    }

    // MARK: - Dual-Mode Lifecycle (PacketTunnel Extension with In-Process Free Account Fallback)
    private func startProxyService(options: [String: Any], result: @escaping FlutterResult) {
        let hasPlugIn = Bundle.main.builtInPlugInsURL.map { url in
            FileManager.default.fileExists(atPath: url.appendingPathComponent("PacketTunnel.appex").path)
        } ?? false

        if !hasPlugIn {
            // Built with FreeSign target (no PacketTunnel.appex) -> start directly in main process
            startInProcessMode(options: options, result: result)
            return
        }

        NETunnelProviderManager.loadAllFromPreferences { [weak self] managers, error in
            guard let self = self else { return }
            if let _ = error {
                // Missing NetworkExtension entitlement (Free Apple ID) -> fallback to In-Process Mode
                self.startInProcessMode(options: options, result: result)
                return
            }

            let manager = managers?.first ?? NETunnelProviderManager()
            let proto = NETunnelProviderProtocol()
            proto.providerBundleIdentifier = (Bundle.main.bundleIdentifier ?? "com.follow.clash.ios") + ".PacketTunnel"
            proto.serverAddress = "FlClash Mihomo Core"
            proto.providerConfiguration = [
                "workDir": self.resolveSharedWorkingDirectory().path,
                "options": options
            ]
            manager.protocolConfiguration = proto
            manager.localizedDescription = "FlClash"
            manager.isEnabled = true

            manager.saveToPreferences { saveError in
                if let _ = saveError {
                    // Free Apple ID cannot save NEPacketTunnelProvider preferences -> fallback seamlessly
                    self.startInProcessMode(options: options, result: result)
                    return
                }
                manager.loadFromPreferences { _ in
                    self.tunnelManager = manager
                    do {
                        try manager.connection.startVPNTunnel(options: nil)
                        self.isRunningInProcess = false
                        self.isCoreStarted = true
                        result(true)
                    } catch {
                        self.startInProcessMode(options: options, result: result)
                    }
                }
            }
        }
    }

    private func startInProcessMode(options: [String: Any], result: @escaping FlutterResult) {
        isRunningInProcess = true
        isCoreStarted = true
        let mixedPort = (options["mixedPort"] as? Int) ?? 7890
        keepAliveManager.startKeepAlive()
        pacServer.start(proxyPort: mixedPort)
        DispatchQueue.main.async { [weak self] in
            self?.serviceChannel.invokeMethod("onServiceStarted", arguments: [
                "mode": "in_process",
                "mixedPort": mixedPort,
                "pacUrl": "http://127.0.0.1:\(self?.pacServer.port ?? 7891)/pac.js"
            ])
        }
        result(true)
    }

    private func stopProxyService(result: @escaping FlutterResult) {
        if isRunningInProcess {
            keepAliveManager.stopKeepAlive()
            pacServer.stop()
            isCoreStarted = false
            result(true)
            return
        }
        tunnelManager?.connection.stopVPNTunnel()
        isCoreStarted = false
        result(true)
    }

    func handleLowMemory() {
        coreQueue.async {
            MobileForceIOSGC()
        }
    }

    private func observeVPNStatus() {
        NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let connection = notification.object as? NEVPNConnection else { return }
            let stateStr: String
            switch connection.status {
            case .connected: stateStr = "connected"
            case .connecting, .reasserting: stateStr = "connecting"
            case .disconnecting: stateStr = "disconnecting"
            case .disconnected, .invalid: stateStr = "disconnected"
            @unknown default: stateStr = "disconnected"
            }
            self?.serviceChannel.invokeMethod("onVpnStatusChanged", arguments: stateStr)
        }
    }
}

private final class IOSEventBridge: NSObject, MobileEventListenerProtocol {
    private let callback: (String) -> Void
    init(callback: @escaping (String) -> Void) {
        self.callback = callback
    }
    func onEvent(_ data: String?) throws {
        guard let data = data else { return }
        callback(data)
    }
}

// Fallback stubs when compiling before `gomobile bind` generates `Core.xcframework`
#if !canImport(Core)
protocol MobileEventListenerProtocol: AnyObject {
    func onEvent(_ data: String?) throws
}
func MobileInitIOSMemoryLimit(_ isExtension: Bool) {}
func MobileSetIOSEventListener(_ listener: MobileEventListenerProtocol?) {}
func MobileInvokeCoreMethod(_ payload: String) -> String { return "{\"ok\":true}" }
func MobileForceIOSGC() {}
#else
import Core
#endif
