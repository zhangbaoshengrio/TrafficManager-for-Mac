import XCTest
@testable import TrafficMonitor

/// 隧道/代理出口进程的外层 socket 承载的是其他应用已计过的字节，必须被识别并丢弃，
/// 否则总量、历史和告警都会重复统计。
final class TunnelEgressTests: XCTestCase {
    func testKnownProxyCoreNameIsTunnelEgress() {
        XCTAssertTrue(ProcessIdentityResolver.isTunnelEgress(execName: "tailscaled", path: ""))
        XCTAssertTrue(ProcessIdentityResolver.isTunnelEgress(execName: "Mihomo", path: ""))
    }

    func testOrdinaryAppIsNotTunnelEgress() {
        XCTAssertFalse(ProcessIdentityResolver.isTunnelEgress(
            execName: "Google Chrome", path: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"))
    }

    func testPacketTunnelExtensionIsDetectedFromInfoPlist() throws {
        let appex = try makeAppex(extensionPoint: "com.apple.networkextension.packet-tunnel")
        XCTAssertTrue(ProcessIdentityResolver.isTunnelEgress(
            execName: "MacPacketTunnel", path: appex + "/Contents/MacOS/MacPacketTunnel"))
    }

    func testNonTunnelExtensionIsNotExcluded() throws {
        let appex = try makeAppex(extensionPoint: "com.apple.widgetkit-extension")
        XCTAssertFalse(ProcessIdentityResolver.isTunnelEgress(
            execName: "WidgetExtension", path: appex + "/Contents/MacOS/WidgetExtension"))
    }

    // MARK: - 夹具

    private func makeAppex(extensionPoint: String) throws -> String {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("Fake.app/Contents/PlugIns/Fake.appex")
        let contents = root.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let info: [String: Any] = ["NSExtension": ["NSExtensionPointIdentifier": extensionPoint]]
        (info as NSDictionary).write(to: contents.appendingPathComponent("Info.plist"), atomically: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root.path
    }
}
