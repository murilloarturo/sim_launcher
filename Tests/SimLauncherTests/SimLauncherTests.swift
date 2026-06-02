import XCTest
@testable import SimLauncher

final class SimLauncherTests: XCTestCase {
    func testPlatformCLIIdentifiersResolveCommonAliases() {
        XCTAssertEqual(SimulatorPlatform.fromCLIIdentifier("apple"), .apple)
        XCTAssertEqual(SimulatorPlatform.fromCLIIdentifier("iphone"), .apple)
        XCTAssertEqual(SimulatorPlatform.fromCLIIdentifier("ipad"), .apple)
        XCTAssertEqual(SimulatorPlatform.fromCLIIdentifier("android"), .android)
        XCTAssertEqual(SimulatorPlatform.fromCLIIdentifier("avd"), .android)
        XCTAssertNil(SimulatorPlatform.fromCLIIdentifier("desktop"))
    }

    func testAppleParserGroupsAvailablePhoneAndTabletDevices() throws {
        let json = """
        {
          "devices": {
            "com.apple.CoreSimulator.SimRuntime.iOS-26-4": [
              {
                "udid": "IPHONE-17-PRO",
                "name": "iPhone 17 Pro",
                "state": "Shutdown",
                "isAvailable": true,
                "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro"
              },
              {
                "udid": "IPAD-PRO",
                "name": "iPad Pro",
                "state": "Shutdown",
                "isAvailable": true,
                "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch"
              },
              {
                "udid": "UNAVAILABLE",
                "name": "iPhone 16",
                "state": "Shutdown",
                "isAvailable": false,
                "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-16"
              }
            ],
            "com.apple.CoreSimulator.SimRuntime.iOS-25-0": [
              {
                "udid": "BOOTED-IPHONE",
                "name": "iPhone 16 Pro",
                "state": "Booted",
                "isAvailable": true,
                "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-16-Pro"
              }
            ]
          }
        }
        """

        let devices = try AppleSimulatorCatalog.parseDevices(from: Data(json.utf8))

        XCTAssertEqual(devices.map(\.id), ["BOOTED-IPHONE", "IPHONE-17-PRO", "IPAD-PRO"])
        XCTAssertEqual(devices[0].runtime, "iOS 25.0")
        XCTAssertEqual(devices[1].runtime, "iOS 26.4")
        XCTAssertEqual(devices[1].detail, "iPhone 17 Pro")
        XCTAssertEqual(devices[1].category, "iPhone")
        XCTAssertEqual(devices[2].category, "iPad")
    }

    func testRuntimeDisplayNameUsesReadableVersion() {
        XCTAssertEqual(
            AppleSimulatorCatalog.displayName(forRuntimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-26-4"),
            "iOS 26.4"
        )
    }

    func testAndroidParserBuildsDevicesFromAVDList() {
        let output = """

        Pixel_4_API_33
        WARNING | ignored warning
        Pixel_6_Pro_API_33
        flutter_emulator

        """

        let devices = AndroidEmulatorCatalog.parseAVDs(from: output)

        XCTAssertEqual(devices.map(\.launchIdentifier), [
            "Pixel_4_API_33",
            "Pixel_6_Pro_API_33",
            "flutter_emulator"
        ])
        XCTAssertEqual(devices.map(\.category), ["Phone", "Phone", "Other"])
        XCTAssertTrue(devices.allSatisfy { $0.platform == .android })
        XCTAssertTrue(devices.allSatisfy(\.isAvailable))
    }
}
