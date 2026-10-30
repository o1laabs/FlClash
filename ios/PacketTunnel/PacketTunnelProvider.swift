import NetworkExtension
import Foundation

#if canImport(Core)
import Core
#endif

final class PacketTunnelProvider: NEPacketTunnelProvider {
    private let coreQueue = DispatchQueue(label: "com.follow.clash.ios.tunnel", qos: .userInitiated)

    override func startTunnel(options: [String : NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        // Enforce 32 MB Go heap cap so NEPacketTunnelProvider stays well below iOS's 50 MB jetsam limit
        #if canImport(Core)
        MobileInitIOSMemoryLimit(true)
        #endif

        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "198.18.0.1")
        settings.mtu = 1400

        let ipv4 = NEIPv4Settings(addresses: ["198.18.0.1"], subnetMasks: ["255.254.0.0"])
        ipv4.includedRoutes = [NEIPv4Route.default()]
        ipv4.excludedRoutes = [
            NEIPv4Route(destinationAddress: "10.0.0.0", subnetMask: "255.0.0.0"),
            NEIPv4Route(destinationAddress: "172.16.0.0", subnetMask: "255.240.0.0"),
            NEIPv4Route(destinationAddress: "192.168.0.0", subnetMask: "255.255.0.0")
        ]
        settings.ipv4Settings = ipv4

        let dns = NEDNSSettings(servers: ["198.18.0.2", "1.1.1.1"])
        dns.matchDomains = [""]
        settings.dnsSettings = dns

        setTunnelNetworkSettings(settings) { [weak self] error in
            if let error = error {
                completionHandler(error)
                return
            }
            guard let self = self else {
                completionHandler(nil)
                return
            }
            let fd = self.resolveTunnelFileDescriptor()
            self.coreQueue.async {
                #if canImport(Core)
                _ = MobileStartIOSTun(Int32(fd), 1400, "gvisor", "198.18.0.2:53")
                #endif
                completionHandler(nil)
            }
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        coreQueue.async {
            #if canImport(Core)
            MobileStopIOSTun()
            #endif
            completionHandler()
        }
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        guard let payload = String(data: messageData, encoding: .utf8) else {
            completionHandler?(nil)
            return
        }
        coreQueue.async {
            #if canImport(Core)
            let response = MobileInvokeCoreMethod(payload)
            completionHandler?(response.data(using: .utf8))
            #else
            completionHandler?("{\"ok\":true}".data(using: .utf8))
            #endif
        }
    }

    private func resolveTunnelFileDescriptor() -> Int32 {
        if let fd = packetFlow.value(forKeyPath: "socket.fileDescriptor") as? Int32 {
            return fd
        }
        var buf = [CChar](repeating: 0, count: Int(IFNAMSIZ))
        for fd: Int32 in 0...1024 {
            var len = socklen_t(buf.count)
            if getsockopt(fd, 2 /* SYSPROTO_CONTROL */, 2 /* UTUN_OPT_IFNAME */, &buf, &len) == 0 {
                let name = String(cString: buf)
                if name.hasPrefix("utun") {
                    return fd
                }
            }
        }
        return -1
    }
}
