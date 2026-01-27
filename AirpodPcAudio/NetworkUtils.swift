import Foundation

enum NetworkUtils {
    /// Returns the device's WiFi IP address, or nil if not connected
    static func getWiFiIPAddress() -> String? {
        var address: String?

        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else {
            return nil
        }

        defer { freeifaddrs(ifaddr) }

        for ifptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let interface = ifptr.pointee
            let addrFamily = interface.ifa_addr.pointee.sa_family

            // Check for IPv4
            if addrFamily == UInt8(AF_INET) {
                let name = String(cString: interface.ifa_name)

                // en0 is WiFi on iOS
                if name == "en0" {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(
                        interface.ifa_addr,
                        socklen_t(interface.ifa_addr.pointee.sa_len),
                        &hostname,
                        socklen_t(hostname.count),
                        nil,
                        0,
                        NI_NUMERICHOST
                    )
                    address = String(cString: hostname)
                }
            }
        }

        return address
    }
}
