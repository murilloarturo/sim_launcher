import AppKit
import Darwin
import Foundation
import ServiceManagement
import SwiftUI

enum SimulatorPlatform: String, CaseIterable, Identifiable, Sendable {
    case apple = "iPhone / iPad"
    case android = "Android"

    var id: String { rawValue }

    var title: String { rawValue }

    var subtitle: String {
        switch self {
        case .apple:
            "CoreSimulator devices"
        case .android:
            "Android Virtual Devices"
        }
    }

    var symbolName: String {
        switch self {
        case .apple:
            "iphone"
        case .android:
            "play.rectangle.fill"
        }
    }

    var accentColor: Color {
        switch self {
        case .apple:
            .blue
        case .android:
            .green
        }
    }

    var cliIdentifier: String {
        switch self {
        case .apple:
            "apple"
        case .android:
            "android"
        }
    }

    static func fromCLIIdentifier(_ value: String) -> SimulatorPlatform? {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "apple", "ios", "iphone", "ipad":
            .apple
        case "android", "avd", "emulator":
            .android
        default:
            nil
        }
    }
}

struct SimulatorDevice: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let platform: SimulatorPlatform
    let category: String
    let runtime: String
    let state: String
    let detail: String
    let isAvailable: Bool
    let launchIdentifier: String
}

struct DeviceCategoryGroup: Identifiable, Equatable {
    let name: String
    let devices: [SimulatorDevice]

    var id: String { name }
}

struct SimulatorDevicePayload: Encodable {
    let platform: String
    let category: String
    let name: String
    let runtime: String
    let state: String
    let id: String
    let launchIdentifier: String

    init(device: SimulatorDevice) {
        platform = device.platform.cliIdentifier
        category = device.category
        name = device.name
        runtime = device.runtime
        state = device.state
        id = device.id
        launchIdentifier = device.launchIdentifier
    }
}

struct SimulatorListPayload: Encodable {
    let devices: [SimulatorDevicePayload]
    let errors: [String: String]
}

struct CommandResult: Equatable, Sendable {
    let exitCode: Int32
    let standardOutput: String
    let standardError: String

    var combinedOutput: String {
        [standardOutput, standardError]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}

protocol CommandRunning {
    func run(executableURL: URL, arguments: [String]) throws -> CommandResult
    func launchDetached(executableURL: URL, arguments: [String]) throws
}

struct ProcessCommandRunner: CommandRunning {
    func run(executableURL: URL, arguments: [String]) throws -> CommandResult {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments

        let stdoutURL = temporaryOutputURL(named: "stdout")
        let stderrURL = temporaryOutputURL(named: "stderr")

        FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
        FileManager.default.createFile(atPath: stderrURL.path, contents: nil)

        let stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
        let stderrHandle = try FileHandle(forWritingTo: stderrURL)

        process.standardOutput = stdoutHandle
        process.standardError = stderrHandle

        defer {
            stdoutHandle.closeFile()
            stderrHandle.closeFile()
            try? FileManager.default.removeItem(at: stdoutURL)
            try? FileManager.default.removeItem(at: stderrURL)
        }

        try process.run()
        process.waitUntilExit()

        let stdout = try String(contentsOf: stdoutURL, encoding: .utf8)
        let stderr = try String(contentsOf: stderrURL, encoding: .utf8)

        return CommandResult(
            exitCode: process.terminationStatus,
            standardOutput: stdout,
            standardError: stderr
        )
    }

    func launchDetached(executableURL: URL, arguments: [String]) throws {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments

        if let nullOutput = FileHandle(forWritingAtPath: "/dev/null") {
            process.standardOutput = nullOutput
            process.standardError = nullOutput
        }

        try process.run()
    }

    private func temporaryOutputURL(named name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("simlauncher-\(UUID().uuidString)-\(name).txt")
    }
}

struct LauncherError: LocalizedError, Equatable {
    let message: String

    var errorDescription: String? { message }
}

struct AppleSimulatorCatalog {
    private struct SimctlList: Decodable {
        let devices: [String: [SimctlDevice]]
    }

    private struct SimctlDevice: Decodable {
        let udid: String
        let name: String
        let state: String
        let isAvailable: Bool?
        let deviceTypeIdentifier: String?
    }

    static func fetch(using runner: any CommandRunning) throws -> [SimulatorDevice] {
        let result = try runner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: ["simctl", "list", "devices", "--json"]
        )

        guard result.exitCode == 0 else {
            throw LauncherError(message: result.combinedOutput.isEmpty ? "Unable to read Apple simulators." : result.combinedOutput)
        }

        return try parseDevices(from: Data(result.standardOutput.utf8))
    }

    static func parseDevices(from data: Data) throws -> [SimulatorDevice] {
        let list = try JSONDecoder().decode(SimctlList.self, from: data)

        return list.devices.flatMap { runtimeIdentifier, devices in
            devices.compactMap { device -> SimulatorDevice? in
                let isAvailable = device.isAvailable ?? true
                let category = category(forDeviceTypeIdentifier: device.deviceTypeIdentifier, name: device.name)
                guard isAvailable, category != "Other" else { return nil }

                return SimulatorDevice(
                    id: device.udid,
                    name: device.name,
                    platform: .apple,
                    category: category,
                    runtime: displayName(forRuntimeIdentifier: runtimeIdentifier),
                    state: device.state,
                    detail: displayName(forDeviceTypeIdentifier: device.deviceTypeIdentifier),
                    isAvailable: isAvailable,
                    launchIdentifier: device.udid
                )
            }
        }
        .sorted(by: sortDevices)
    }

    static func displayName(forRuntimeIdentifier identifier: String) -> String {
        let rawName = identifier.split(separator: ".").last.map(String.init) ?? identifier
        let pieces = rawName.split(separator: "-").map(String.init)

        guard let family = pieces.first else { return rawName }

        let version = pieces.dropFirst().joined(separator: ".")
        return version.isEmpty ? family : "\(family) \(version)"
    }

    static func displayName(forDeviceTypeIdentifier identifier: String?) -> String {
        guard let identifier else { return "Apple Simulator" }

        let rawName = identifier.split(separator: ".").last.map(String.init) ?? identifier
        return rawName.replacingOccurrences(of: "-", with: " ")
    }

    static func category(forDeviceTypeIdentifier identifier: String?, name: String) -> String {
        let combined = "\(identifier ?? "") \(name)".lowercased()

        if combined.contains("iphone") { return "iPhone" }
        if combined.contains("ipad") { return "iPad" }
        if combined.contains("watch") { return "Apple Watch" }
        if combined.contains("appletv") || combined.contains("apple-tv") { return "Apple TV" }
        if combined.contains("vision") { return "Apple Vision" }

        return "Other"
    }
}

struct AndroidEmulatorCatalog {
    static func fetch(using runner: any CommandRunning) throws -> [SimulatorDevice] {
        guard let emulatorURL = emulatorExecutableURL() else {
            throw LauncherError(message: "Android emulator was not found. Set ANDROID_HOME or ANDROID_SDK_ROOT, or install the SDK at ~/Library/Android/sdk.")
        }

        let result = try runner.run(
            executableURL: emulatorURL,
            arguments: ["-list-avds"]
        )

        guard result.exitCode == 0 else {
            throw LauncherError(message: result.combinedOutput.isEmpty ? "Unable to read Android virtual devices." : result.combinedOutput)
        }

        return parseAVDs(from: result.standardOutput)
    }

    static func parseAVDs(from output: String) -> [SimulatorDevice] {
        output
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { line in
                !line.isEmpty
                    && !line.hasPrefix("INFO")
                    && !line.hasPrefix("WARNING")
            }
            .map { avdName in
                SimulatorDevice(
                    id: "android-\(avdName)",
                    name: avdName,
                    platform: .android,
                    category: category(forAVDName: avdName),
                    runtime: "Android Virtual Device",
                    state: "Available",
                    detail: "AVD",
                    isAvailable: true,
                    launchIdentifier: avdName
                )
            }
            .sorted(by: sortDevices)
    }

    static func category(forAVDName name: String) -> String {
        let normalized = name.lowercased()

        if normalized.contains("tablet") || normalized.contains("pixel_c") || normalized.contains("nexus_10") {
            return "Tablet"
        }

        if normalized.contains("fold") {
            return "Foldable"
        }

        if normalized.contains("wear") || normalized.contains("watch") {
            return "Wear"
        }

        if normalized.contains("tv") {
            return "TV"
        }

        if normalized.contains("auto") {
            return "Automotive"
        }

        if normalized.contains("pixel") || normalized.contains("phone") || normalized.contains("nexus") {
            return "Phone"
        }

        return "Other"
    }

    static func emulatorExecutableURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> URL? {
        let sdkRoots = ["ANDROID_HOME", "ANDROID_SDK_ROOT"]
            .compactMap { environment[$0] }

        let homeSDK = fileManager
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Android/sdk")
            .path

        let candidates = (sdkRoots + [homeSDK])
            .map { URL(fileURLWithPath: $0).appendingPathComponent("emulator/emulator") }

        return candidates.first { fileManager.isExecutableFile(atPath: $0.path) }
    }
}

private func sortDevices(_ lhs: SimulatorDevice, _ rhs: SimulatorDevice) -> Bool {
    if lhs.category != rhs.category {
        return categoryRank(lhs.category) < categoryRank(rhs.category)
    }

    if lhs.state == "Booted", rhs.state != "Booted" { return true }
    if lhs.state != "Booted", rhs.state == "Booted" { return false }
    if lhs.runtime != rhs.runtime { return lhs.runtime > rhs.runtime }
    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
}

private func categoryRank(_ category: String) -> Int {
    [
        "iPhone": 0,
        "iPad": 1,
        "Phone": 2,
        "Tablet": 3,
        "Foldable": 4,
        "Wear": 5,
        "Apple Watch": 6,
        "TV": 7,
        "Apple TV": 8,
        "Automotive": 9,
        "Apple Vision": 10,
        "Other": 99
    ][category] ?? 98
}

struct SimulatorService {
    private let runner: any CommandRunning

    init(runner: any CommandRunning = ProcessCommandRunner()) {
        self.runner = runner
    }

    func devices(for platform: SimulatorPlatform) throws -> [SimulatorDevice] {
        switch platform {
        case .apple:
            try AppleSimulatorCatalog.fetch(using: runner)
        case .android:
            try AndroidEmulatorCatalog.fetch(using: runner)
        }
    }

    func launch(_ device: SimulatorDevice) throws {
        switch device.platform {
        case .apple:
            try launchApple(device)
        case .android:
            try launchAndroid(device)
        }
    }

    private func launchApple(_ device: SimulatorDevice) throws {
        let bootResult = try runner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: ["simctl", "boot", device.launchIdentifier]
        )

        let bootOutput = bootResult.combinedOutput
        let alreadyBooted = bootOutput.localizedCaseInsensitiveContains("booted")

        guard bootResult.exitCode == 0 || alreadyBooted else {
            throw LauncherError(message: bootOutput.isEmpty ? "Unable to boot \(device.name)." : bootOutput)
        }

        let openResult = try runner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/open"),
            arguments: ["-a", "Simulator"]
        )

        guard openResult.exitCode == 0 else {
            throw LauncherError(message: openResult.combinedOutput.isEmpty ? "Unable to open Simulator.app." : openResult.combinedOutput)
        }
    }

    private func launchAndroid(_ device: SimulatorDevice) throws {
        guard let emulatorURL = AndroidEmulatorCatalog.emulatorExecutableURL() else {
            throw LauncherError(message: "Android emulator was not found. Set ANDROID_HOME or ANDROID_SDK_ROOT, or install the SDK at ~/Library/Android/sdk.")
        }

        try runner.launchDetached(
            executableURL: emulatorURL,
            arguments: ["-avd", device.launchIdentifier]
        )
    }
}

@MainActor
final class SimulatorMenuController: ObservableObject {
    @Published private(set) var devicesByPlatform: [SimulatorPlatform: [SimulatorDevice]] = [:]
    @Published private(set) var platformErrors: [SimulatorPlatform: String] = [:]
    @Published private(set) var isRefreshing = false
    @Published private(set) var statusText = "Ready"
    @Published private(set) var detailText = "Choose a simulator to launch."
    @Published private(set) var lastUpdatedText = "Not scanned yet"

    private let service: SimulatorService

    init(service: SimulatorService = SimulatorService()) {
        self.service = service
    }

    func refreshAll() {
        isRefreshing = true
        statusText = "Scanning"
        detailText = "Looking for local simulators."

        var nextDevices: [SimulatorPlatform: [SimulatorDevice]] = [:]
        var nextErrors: [SimulatorPlatform: String] = [:]

        for platform in SimulatorPlatform.allCases {
            do {
                nextDevices[platform] = try service.devices(for: platform)
            } catch {
                nextDevices[platform] = []
                nextErrors[platform] = error.localizedDescription
            }
        }

        devicesByPlatform = nextDevices
        platformErrors = nextErrors
        updateSummary()
        isRefreshing = false
    }

    func refresh(_ platform: SimulatorPlatform) {
        isRefreshing = true

        do {
            devicesByPlatform[platform] = try service.devices(for: platform)
            platformErrors[platform] = nil
        } catch {
            devicesByPlatform[platform] = []
            platformErrors[platform] = error.localizedDescription
        }

        updateSummary()
        isRefreshing = false
    }

    func launch(_ device: SimulatorDevice) {
        statusText = "Launching"
        detailText = "Opening \(device.name)."

        do {
            try service.launch(device)
            statusText = "Launched"
            detailText = "\(device.name) is starting."
            refresh(device.platform)
        } catch {
            statusText = "Launch Failed"
            detailText = error.localizedDescription
        }
    }

    func groups(for platform: SimulatorPlatform) -> [DeviceCategoryGroup] {
        let grouped = Dictionary(grouping: devicesByPlatform[platform, default: []], by: \.category)

        return grouped
            .map { category, devices in
                DeviceCategoryGroup(name: category, devices: devices.sorted(by: sortDevices))
            }
            .sorted { lhs, rhs in
                let leftRank = categoryRank(lhs.name)
                let rightRank = categoryRank(rhs.name)

                if leftRank != rightRank { return leftRank < rightRank }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    func count(for platform: SimulatorPlatform) -> Int {
        devicesByPlatform[platform, default: []].count
    }

    private func updateSummary() {
        let total = SimulatorPlatform.allCases
            .map { count(for: $0) }
            .reduce(0, +)

        statusText = total == 0 ? "No Devices" : "\(total) Ready"
        detailText = SimulatorPlatform.allCases
            .map { "\($0.title): \(count(for: $0))" }
            .joined(separator: " | ")
        lastUpdatedText = Self.currentTimestamp()
    }

    private static func currentTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return "Updated \(formatter.string(from: Date()))"
    }
}

struct SimLauncherCLI {
    let arguments: [String]
    private let service = SimulatorService()

    static func shouldHandle(arguments: [String]) -> Bool {
        guard let command = arguments.first else { return false }
        return ["list", "launch", "help", "--help", "-h"].contains(command)
    }

    func run() throws {
        guard let command = arguments.first else {
            printHelp()
            return
        }

        switch command {
        case "list":
            try listDevices()
        case "launch":
            try launchDevice()
        case "help", "--help", "-h":
            printHelp()
        default:
            throw LauncherError(message: "Unknown command: \(command)\n\n\(helpText)")
        }
    }

    private func listDevices() throws {
        let platforms = try requestedPlatforms()
        var devices: [SimulatorDevice] = []
        var errors: [String: String] = [:]

        for platform in platforms {
            do {
                devices.append(contentsOf: try service.devices(for: platform))
            } catch {
                errors[platform.cliIdentifier] = error.localizedDescription
            }
        }

        if hasFlag("--json") {
            let payload = SimulatorListPayload(
                devices: devices.map(SimulatorDevicePayload.init(device:)),
                errors: errors
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(payload)
            print(String(decoding: data, as: UTF8.self))
        } else {
            printDeviceList(devices: devices, errors: errors, platforms: platforms)
        }

        if !errors.isEmpty && devices.isEmpty {
            let message = errors
                .map { "\($0.key): \($0.value)" }
                .sorted()
                .joined(separator: "\n")
            throw LauncherError(message: message)
        }
    }

    private func launchDevice() throws {
        guard let platformValue = optionValue(["--platform", "-p"]),
              let platform = SimulatorPlatform.fromCLIIdentifier(platformValue) else {
            throw LauncherError(message: "Launch requires --platform apple|android.")
        }

        let device = try resolveDevice(
            platform: platform,
            id: optionValue(["--id", "--udid"]),
            name: optionValue(["--name"]),
            category: optionValue(["--category"])
        )

        try service.launch(device)
        print("Launched \(device.name) (\(device.platform.cliIdentifier)/\(device.category))")
    }

    private func resolveDevice(
        platform: SimulatorPlatform,
        id: String?,
        name: String?,
        category: String?
    ) throws -> SimulatorDevice {
        guard id != nil || name != nil else {
            throw LauncherError(message: "Launch requires --id <device-id> or --name <device-name>.")
        }

        var devices = try service.devices(for: platform)

        if let category {
            devices = devices.filter { $0.category.localizedCaseInsensitiveCompare(category) == .orderedSame }
        }

        let matches: [SimulatorDevice]

        if let id {
            matches = devices.filter {
                $0.id.localizedCaseInsensitiveCompare(id) == .orderedSame
                    || $0.launchIdentifier.localizedCaseInsensitiveCompare(id) == .orderedSame
            }
        } else if let name {
            let exactMatches = devices.filter {
                $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame
            }
            matches = exactMatches.isEmpty
                ? devices.filter { $0.name.localizedCaseInsensitiveContains(name) }
                : exactMatches
        } else {
            matches = []
        }

        guard matches.count == 1 else {
            if matches.isEmpty {
                throw LauncherError(message: "No matching \(platform.title) device found. Run `scripts/simlauncherctl list --platform \(platform.cliIdentifier)`.")
            }

            let options = matches
                .map { "- \($0.name) [id: \($0.launchIdentifier)] \($0.runtime)" }
                .joined(separator: "\n")
            throw LauncherError(message: "Multiple devices matched. Use --id with one of:\n\(options)")
        }

        return matches[0]
    }

    private func requestedPlatforms() throws -> [SimulatorPlatform] {
        guard let platformValue = optionValue(["--platform", "-p"]) else {
            return SimulatorPlatform.allCases
        }

        guard let platform = SimulatorPlatform.fromCLIIdentifier(platformValue) else {
            throw LauncherError(message: "Unknown platform: \(platformValue). Use apple or android.")
        }

        return [platform]
    }

    private func printDeviceList(
        devices: [SimulatorDevice],
        errors: [String: String],
        platforms: [SimulatorPlatform]
    ) {
        for platform in platforms {
            let platformDevices = devices.filter { $0.platform == platform }
            print("\(platform.title) (\(platformDevices.count))")

            if let error = errors[platform.cliIdentifier] {
                print("  Error: \(error)")
                continue
            }

            if platformDevices.isEmpty {
                print("  No devices found")
                continue
            }

            for group in groupedDevices(platformDevices) {
                print("  \(group.name)")
                for device in group.devices {
                    print("    \(device.name) [id: \(device.launchIdentifier)] \(device.runtime) \(device.state)")
                }
            }
        }
    }

    private func groupedDevices(_ devices: [SimulatorDevice]) -> [DeviceCategoryGroup] {
        Dictionary(grouping: devices, by: \.category)
            .map { category, devices in
                DeviceCategoryGroup(name: category, devices: devices.sorted(by: sortDevices))
            }
            .sorted { lhs, rhs in
                let leftRank = categoryRank(lhs.name)
                let rightRank = categoryRank(rhs.name)

                if leftRank != rightRank { return leftRank < rightRank }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    private func hasFlag(_ flag: String) -> Bool {
        arguments.contains(flag)
    }

    private func optionValue(_ names: [String]) -> String? {
        for (index, argument) in arguments.enumerated() {
            if names.contains(argument), arguments.indices.contains(index + 1) {
                return arguments[index + 1]
            }

            for name in names where argument.hasPrefix("\(name)=") {
                return String(argument.dropFirst(name.count + 1))
            }
        }

        return nil
    }

    private func printHelp() {
        print(helpText)
    }

    private var helpText: String {
        """
        SimLauncher agent commands

        Usage:
          SimLauncher list [--json] [--platform apple|android]
          SimLauncher launch --platform apple|android (--id <id> | --name <name>) [--category <category>]

        Examples:
          SimLauncher list --json
          SimLauncher list --platform apple
          SimLauncher launch --platform apple --id C2E7124E-2C96-41C0-8985-27BF4DA397C8
          SimLauncher launch --platform android --name Pixel_6_Pro_API_33
        """
    }
}

@MainActor
final class LoginItemController: ObservableObject {
    @Published private(set) var isOpenAtLoginEnabled = false
    @Published private(set) var statusText = "Checking..."
    @Published private(set) var detailText: String?
    @Published private(set) var needsApproval = false

    private let service = SMAppService.mainApp

    init() {
        refresh()
    }

    func setOpenAtLogin(_ isEnabled: Bool) {
        do {
            let status = service.status

            if isEnabled {
                if status != .enabled && status != .requiresApproval {
                    try service.register()
                }
            } else if status == .enabled || status == .requiresApproval {
                try service.unregister()
            }

            refresh()
        } catch {
            refresh()
            detailText = error.localizedDescription
        }
    }

    func refresh() {
        switch service.status {
        case .enabled:
            isOpenAtLoginEnabled = true
            needsApproval = false
            statusText = "Enabled"
            detailText = nil
        case .requiresApproval:
            isOpenAtLoginEnabled = true
            needsApproval = true
            statusText = "Needs Approval"
            detailText = "Allow SimLauncher in Login Items."
        case .notRegistered:
            isOpenAtLoginEnabled = false
            needsApproval = false
            statusText = "Disabled"
            detailText = nil
        case .notFound:
            isOpenAtLoginEnabled = false
            needsApproval = false
            statusText = "Unavailable"
            detailText = "Run SimLauncher from its app bundle."
        @unknown default:
            isOpenAtLoginEnabled = false
            needsApproval = false
            statusText = "Unknown"
            detailText = nil
        }
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

struct MenuBarHomeView: View {
    @ObservedObject var controller: SimulatorMenuController
    @ObservedObject var loginItemController: LoginItemController

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color.black.opacity(0.025), Color.black.opacity(0.08)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            VStack(alignment: .leading, spacing: 16) {
                heroStateCard
                launcherSection
                controlsSection
                loginItemSection
                quitButton
            }
            .padding(16)
        }
        .frame(width: 410)
        .onAppear {
            controller.refreshAll()
            loginItemController.refresh()
        }
    }

    private var heroStateCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "iphone.gen3.radiowaves.left.and.right")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(statusTint)
                    .frame(width: 36, height: 36)
                    .background(statusTint.opacity(0.14), in: RoundedRectangle(cornerRadius: 9, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text("SimLauncher")
                        .font(.headline.weight(.semibold))
                    Text("Open local simulators from the menu bar.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                statusPill(controller.statusText, tint: statusTint)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(controller.detailText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    Circle()
                        .fill(statusTint)
                        .frame(width: 8, height: 8)
                    Text(controller.lastUpdatedText)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
    }

    private var launcherSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Launch Simulator")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary.opacity(0.9))

            platformMenu(.apple)
            platformMenu(.android)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(0.055))
        )
    }

    private var controlsSection: some View {
        HStack(spacing: 10) {
            Label("Choose platform, category, then device", systemImage: "list.bullet.indent")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer()

            Button {
                controller.refreshAll()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.bordered)
            .help("Refresh simulators")
            .disabled(controller.isRefreshing)
        }
        .padding(.horizontal, 2)
    }

    private var loginItemSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: Binding(
                get: { loginItemController.isOpenAtLoginEnabled },
                set: { loginItemController.setOpenAtLogin($0) }
            )) {
                HStack(alignment: .center, spacing: 10) {
                    Image(systemName: "power.circle.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(loginItemController.isOpenAtLoginEnabled ? .green : .secondary)
                        .frame(width: 30, height: 30)
                        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Open at Login")
                            .font(.subheadline.weight(.medium))
                        Text(loginItemController.statusText)
                            .font(.caption)
                            .foregroundStyle(loginItemController.needsApproval ? .orange : .secondary)
                    }
                }
            }
            .toggleStyle(RightCheckToggleStyle(isLocked: false, tint: .green))

            if let detailText = loginItemController.detailText {
                Text(detailText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if loginItemController.needsApproval {
                Button {
                    loginItemController.openLoginItemsSettings()
                } label: {
                    Label("Open Login Items", systemImage: "gearshape.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(0.055))
        )
    }

    private var quitButton: some View {
        Button {
            NSApplication.shared.terminate(nil)
        } label: {
            Label("Quit SimLauncher", systemImage: "xmark.circle.fill")
                .frame(maxWidth: .infinity)
        }
        .controlSize(.regular)
        .buttonStyle(.borderedProminent)
        .tint(.gray.opacity(0.45))
    }

    private var statusTint: Color {
        switch controller.statusText {
        case "Launch Failed":
            .orange
        case "Launched":
            .green
        case "No Devices":
            .gray
        default:
            .blue
        }
    }

    private func platformMenu(_ platform: SimulatorPlatform) -> some View {
        Menu {
            if let error = controller.platformErrors[platform] {
                Text(error)
            } else if controller.groups(for: platform).isEmpty {
                Text(emptyText(for: platform))
            } else {
                ForEach(controller.groups(for: platform)) { group in
                    categoryMenu(group)
                }
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: platform.symbolName)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(platform.accentColor)
                    .frame(width: 34, height: 34)
                    .background(platform.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(platform.title)
                        .font(.subheadline.weight(.semibold))
                    Text(platform.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                HStack(spacing: 8) {
                    Text("\(controller.count(for: platform))")
                        .font(.caption.weight(.bold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.primary.opacity(0.08), in: Capsule())
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func categoryMenu(_ group: DeviceCategoryGroup) -> some View {
        Menu {
            ForEach(group.devices) { device in
                Button {
                    controller.launch(device)
                } label: {
                    Label(deviceLabel(for: device), systemImage: device.state == "Booted" ? "checkmark.circle.fill" : "play.circle")
                }
            }
        } label: {
            Label("\(group.name) (\(group.devices.count))", systemImage: categorySymbol(for: group.name))
        }
    }

    private func statusPill(_ text: String, tint: Color) -> some View {
        Text(text.uppercased())
            .font(.caption2.weight(.bold))
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.primary.opacity(0.08), in: Capsule())
            .foregroundStyle(tint)
    }

    private func deviceLabel(for device: SimulatorDevice) -> String {
        if device.state == "Booted" {
            return "\(device.name) - \(device.runtime) - Booted"
        }

        return "\(device.name) - \(device.runtime)"
    }

    private func emptyText(for platform: SimulatorPlatform) -> String {
        switch platform {
        case .apple:
            "No iPhone or iPad simulators found"
        case .android:
            "No Android emulators found"
        }
    }

    private func categorySymbol(for category: String) -> String {
        switch category {
        case "iPhone", "Phone":
            "iphone"
        case "iPad", "Tablet":
            "ipad"
        case "Foldable":
            "rectangle.expand.vertical"
        case "Wear", "Apple Watch":
            "applewatch"
        case "TV", "Apple TV":
            "tv"
        case "Automotive":
            "car.fill"
        case "Apple Vision":
            "visionpro"
        default:
            "rectangle.stack.fill"
        }
    }
}

struct RightCheckToggleStyle: ToggleStyle {
    let isLocked: Bool
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        Button {
            guard !isLocked else { return }
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: 10) {
                configuration.label
                Spacer()
                Image(systemName: configuration.isOn ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(configuration.isOn ? tint : .secondary.opacity(0.7))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(configuration.isOn ? tint.opacity(0.14) : Color.primary.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(configuration.isOn ? tint.opacity(0.35) : Color.primary.opacity(0.08), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

@main
struct SimLauncherApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var controller = SimulatorMenuController()
    @StateObject private var loginItemController = LoginItemController()

    init() {
        var cliArguments = Array(CommandLine.arguments.dropFirst())

        if cliArguments.first == "--" {
            cliArguments.removeFirst()
        }

        guard SimLauncherCLI.shouldHandle(arguments: cliArguments) else { return }

        do {
            try SimLauncherCLI(arguments: cliArguments).run()
            Darwin.exit(EXIT_SUCCESS)
        } catch {
            fputs("SimLauncher: \(error.localizedDescription)\n", stderr)
            Darwin.exit(EXIT_FAILURE)
        }
    }

    var body: some Scene {
        MenuBarExtra("SimLauncher", systemImage: "iphone") {
            MenuBarHomeView(controller: controller, loginItemController: loginItemController)
        }
        .menuBarExtraStyle(.window)
    }
}
