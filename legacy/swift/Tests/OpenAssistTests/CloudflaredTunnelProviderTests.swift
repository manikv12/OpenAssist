import Foundation
import XCTest
@testable import OpenAssist

final class CloudflaredTunnelProviderTests: XCTestCase {
    func testQuickTunnelArgumentsIncludeProtocolAndLocalURL() {
        let configuration = RemoteTunnelConfiguration(
            mode: .quick,
            transport: .http2,
            localPort: 45832,
            manualExecutablePath: "",
            namedTunnelToken: "",
            namedTunnelName: "openassist",
            namedTunnelPublicURL: "https://remote.example.com",
            namedTunnelCredentialsFile: ""
        )

        XCTAssertEqual(
            CloudflaredTunnelProvider.arguments(for: configuration),
            ["tunnel", "--protocol", "http2", "--url", "http://127.0.0.1:45832"]
        )
    }

    func testNamedTunnelArgumentsUseRunModeAndToken() {
        let configuration = RemoteTunnelConfiguration(
            mode: .named,
            transport: .auto,
            localPort: 45832,
            manualExecutablePath: "",
            namedTunnelToken: "token-123",
            namedTunnelName: "openassist",
            namedTunnelPublicURL: "https://remote.example.com",
            namedTunnelCredentialsFile: ""
        )

        XCTAssertEqual(
            CloudflaredTunnelProvider.arguments(for: configuration),
            ["tunnel", "--no-autoupdate", "run", "--token", "token-123"]
        )
    }

    func testLocalNamedTunnelArgumentsUseGeneratedConfig() throws {
        let configuration = RemoteTunnelConfiguration(
            mode: .named,
            transport: .auto,
            localPort: 45832,
            manualExecutablePath: "",
            namedTunnelToken: "",
            namedTunnelName: "openassist",
            namedTunnelPublicURL: "https://remote.example.com",
            namedTunnelCredentialsFile: "~/custom/openassist.json"
        )

        let arguments = try CloudflaredTunnelProvider.launchArguments(
            for: configuration,
            localNamedTunnelConfigPath: "/tmp/openassist.yml"
        )

        XCTAssertEqual(arguments.first, "tunnel")
        XCTAssertEqual(arguments[1], "--config")
        XCTAssertTrue(arguments[2].hasSuffix("openassist.yml"))
        XCTAssertEqual(Array(arguments.suffix(3)), ["--no-autoupdate", "run", "openassist"])
    }

    func testLocalNamedTunnelConfigMapsHostnameToHelper() throws {
        let configuration = RemoteTunnelConfiguration(
            mode: .named,
            transport: .auto,
            localPort: 45832,
            manualExecutablePath: "",
            namedTunnelToken: "",
            namedTunnelName: "openassist",
            namedTunnelPublicURL: "https://remote.example.com",
            namedTunnelCredentialsFile: "~/custom/openassist.json"
        )

        let config = try CloudflaredTunnelProvider.localNamedTunnelConfigText(for: configuration)

        XCTAssertTrue(config.contains("tunnel: openassist"))
        XCTAssertTrue(config.contains("credentials-file: '\(FileManager.default.homeDirectoryForCurrentUser.path)/custom/openassist.json'"))
        XCTAssertTrue(config.contains("hostname: remote.example.com"))
        XCTAssertTrue(config.contains("service: http://127.0.0.1:45832"))
        XCTAssertTrue(config.contains("service: http_status:404"))
    }

    func testExtractQuickTunnelURLFromLogs() {
        let line = "INF | Your quick Tunnel has been created! Visit it at https://fancy-glade.trycloudflare.com"
        XCTAssertEqual(
            CloudflaredTunnelProvider.extractQuickTunnelURL(from: line)?.absoluteString,
            "https://fancy-glade.trycloudflare.com"
        )
    }

    func testExtractMetricsURLFromLogs() {
        let line = "INF Starting metrics server on http://127.0.0.1:20241/metrics"
        XCTAssertEqual(
            CloudflaredTunnelProvider.extractMetricsURL(from: line)?.absoluteString,
            "http://127.0.0.1:20241/metrics"
        )
    }

    func testExtractQuickTunnelURLFromMetricsText() {
        let metrics = """
        # HELP tunnel_ha_connections Number of active connections
        tunnel_userHostname{index="0"} https://steady-moon.trycloudflare.com
        """

        XCTAssertEqual(
            CloudflaredTunnelProvider.quickTunnelURL(fromMetricsText: metrics)?.absoluteString,
            "https://steady-moon.trycloudflare.com"
        )
    }

    func testExtractTunnelIDFromCloudflaredInfoOutput() {
        let output = "Your tunnel 2c647918-89ba-4721-926d-0c7ec1fcfcef does not have any active connection."

        XCTAssertEqual(
            CloudflaredTunnelProvider.tunnelID(fromCloudflaredInfoOutput: output),
            "2c647918-89ba-4721-926d-0c7ec1fcfcef"
        )
    }
}
