import Foundation
import Network

/// 全局轻量网络监听器（基于系统原生 NWPathMonitor，能耗与资源开销极低）
final class NetworkMonitor: ObservableObject {
    static let shared = NetworkMonitor()

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.atmusic.networkmonitor", qos: .utility)

    @Published private(set) var isConnected: Bool = true
    @Published private(set) var isCellular: Bool = false
    @Published private(set) var isWiFi: Bool = false

    var onPathUpdate: (() -> Void)?

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let connected = path.status == .satisfied
            let cellular = path.usesInterfaceType(.cellular)
            let wifi = path.usesInterfaceType(.wifi)

            DispatchQueue.main.async {
                self.isConnected = connected
                self.isCellular = cellular
                self.isWiFi = wifi
                self.onPathUpdate?()
            }
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }
}
