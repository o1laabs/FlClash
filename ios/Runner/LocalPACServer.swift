import Foundation
import Network

/// Lightweight local HTTP server on 127.0.0.1:7891 for Personal Free Apple ID users.
/// Provides:
/// - `http://127.0.0.1:7891/pac.js`: Standard PAC script pointing to Mihomo's Mixed Port (`127.0.0.1:7890`).
/// - `http://127.0.0.1:7891/proxy.mobileconfig`: One-tap iOS configuration profile for automatic Wi-Fi proxy setup.
final class LocalPACServer {
    let port: UInt16 = 7891
    private var listener: NWListener?
    private var proxyPort: Int = 7890

    func start(proxyPort: Int = 7890) {
        self.proxyPort = proxyPort
        stop()
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return }
        do {
            let l = try NWListener(using: .tcp, on: nwPort)
            l.newConnectionHandler = { [weak self] conn in
                self?.handleConnection(conn)
            }
            l.start(queue: .global(qos: .utility))
            self.listener = l
        } catch {
            // Port already bound
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func handleConnection(_ conn: NWConnection) {
        conn.start(queue: .global(qos: .utility))
        conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, _, _ in
            guard let self = self else { return }
            let req = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let body: String
            let contentType: String

            if req.contains("/proxy.mobileconfig") {
                contentType = "application/x-apple-aspen-config"
                body = self.buildMobileConfig()
            } else {
                contentType = "application/x-ns-proxy-autoconfig"
                body = """
                function FindProxyForURL(url, host) {
                    if (isPlainHostName(host) ||
                        shExpMatch(host, "*.local") ||
                        isInNet(dnsResolve(host), "10.0.0.0", "255.0.0.0") ||
                        isInNet(dnsResolve(host), "172.16.0.0", "255.240.0.0") ||
                        isInNet(dnsResolve(host), "192.168.0.0", "255.255.0.0") ||
                        isInNet(dnsResolve(host), "127.0.0.0", "255.0.0.0")) {
                        return "DIRECT";
                    }
                    return "PROXY 127.0.0.1:\(self.proxyPort); SOCKS5 127.0.0.1:\(self.proxyPort); DIRECT";
                }
                """
            }

            let bodyData = body.data(using: .utf8) ?? Data()
            let header = "HTTP/1.1 200 OK\r\nContent-Type: \(contentType)\r\nContent-Length: \(bodyData.count)\r\nConnection: close\r\n\r\n"
            var resp = header.data(using: .utf8) ?? Data()
            resp.append(bodyData)
            conn.send(content: resp, completion: .contentProcessed { _ in
                conn.cancel()
            })
        }
    }

    private func buildMobileConfig() -> String {
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>PayloadContent</key>
            <array>
                <dict>
                    <key>PayloadDescription</key>
                    <string>FlClash Local PAC Proxy Helper</string>
                    <key>PayloadDisplayName</key>
                    <string>FlClash Local Proxy</string>
                    <key>PayloadIdentifier</key>
                    <string>com.follow.clash.ios.pac</string>
                    <key>PayloadType</key>
                    <string>com.apple.proxy.http.global</string>
                    <key>PayloadUUID</key>
                    <string>9A6B5C4D-1111-2222-3333-444455556666</string>
                    <key>PayloadVersion</key>
                    <integer>1</integer>
                    <key>ProxyCaptiveLoginAllowed</key>
                    <true/>
                    <key>ProxyPACFallbackAllowed</key>
                    <true/>
                    <key>ProxyPACURL</key>
                    <string>http://127.0.0.1:\(port)/pac.js</string>
                    <key>ProxyType</key>
                    <string>Auto</string>
                </dict>
            </array>
            <key>PayloadDisplayName</key>
            <string>FlClash iOS Local Proxy (Free Apple ID Mode)</string>
            <key>PayloadIdentifier</key>
            <string>com.follow.clash.ios.profile</string>
            <key>PayloadRemovalDisallowed</key>
            <false/>
            <key>PayloadType</key>
            <string>Configuration</string>
            <key>PayloadUUID</key>
            <string>11223344-5566-7788-99AA-BBCCDDEEFF00</string>
            <key>PayloadVersion</key>
            <integer>1</integer>
        </dict>
        </plist>
        """
    }
}
