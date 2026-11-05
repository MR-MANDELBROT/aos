import Foundation
import Virtualization

/// Settings of the VM that are fixed when it is created (some can change later, see `VMSettings`).
public struct VMSettings: Codable, Sendable, Equatable {
    public var cpuCount: Int
    public var memoryMiB: UInt64
    public var diskGiB: UInt64
    /// The guest screen. 1280x800 at 1x: screenshots need no scaling, so coordinates Claude sees are
    /// the guest's own pixels.
    public var displayWidth: Int
    public var displayHeight: Int
    public var displayPPI: Int

    public static let standard = VMSettings(cpuCount: 4, memoryMiB: 4096, diskGiB: 64,
                                            displayWidth: 1280, displayHeight: 800, displayPPI: 110)
}

/// What the bundle knows about itself (config.json).
public struct VMState: Codable, Sendable, Equatable {
    public var settings: VMSettings
    /// Stable MAC address, so the guest keeps its DHCP lease and we can find its IP.
    public var macAddress: String
    public var createdAt: Date
    /// Build of the macOS that was installed (e.g. "26B123").
    public var guestBuild: String?
    public var guestVersion: String?
    /// Set once the guest was started with provisioning options (account, auto login, SSH).
    public var provisioned: Bool
    /// Set once the guest bootstrap over SSH finished (keys, sshd lock-down, guest kit).
    public var bootstrapped: Bool
    /// Set once screen sharing inside the guest delivers a picture.
    public var screenSharingReady: Bool
}

public enum VMBundleError: LocalizedError {
    case missing(String)
    case unsupportedHost(String)
    case corrupt(String)

    public var errorDescription: String? {
        switch self {
        case .missing(let what): return "The workspace is missing \(what)."
        case .unsupportedHost(let why): return "This Mac can't run the workspace: \(why)"
        case .corrupt(let what): return "The workspace file \(what) is damaged."
        }
    }
}

/// The on-disk VM: a directory with the disk image, auxiliary storage, hardware model, machine
/// identifier and config.json.
public struct VMBundle: Sendable {
    public let url: URL

    public init(url: URL) { self.url = url }

    public var diskURL: URL { url.appendingPathComponent("disk.img") }
    public var auxiliaryStorageURL: URL { url.appendingPathComponent("aux.img") }
    public var hardwareModelURL: URL { url.appendingPathComponent("hardware-model.bin") }
    public var machineIdentifierURL: URL { url.appendingPathComponent("machine-identifier.bin") }
    public var stateURL: URL { url.appendingPathComponent("config.json") }
    /// Saved machine state while the VM is suspended.
    public var savedStateURL: URL { url.appendingPathComponent("suspended.vzvmsave") }

    public var exists: Bool {
        FileManager.default.fileExists(atPath: stateURL.path) && FileManager.default.fileExists(atPath: diskURL.path)
    }

    public func loadState() throws -> VMState {
        guard let data = FileManager.default.contents(atPath: stateURL.path) else {
            throw VMBundleError.missing("config.json")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do { return try decoder.decode(VMState.self, from: data) } catch { throw VMBundleError.corrupt("config.json") }
    }

    public func saveState(_ state: VMState) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(state).write(to: stateURL, options: .atomic)
    }

    public func updateState(_ change: (inout VMState) -> Void) throws {
        var state = try loadState()
        change(&state)
        try saveState(state)
    }

    public func hardwareModel() throws -> VZMacHardwareModel {
        guard let data = FileManager.default.contents(atPath: hardwareModelURL.path) else {
            throw VMBundleError.missing("hardware model")
        }
        guard let model = VZMacHardwareModel(dataRepresentation: data) else {
            throw VMBundleError.corrupt("hardware-model.bin")
        }
        guard model.isSupported else {
            throw VMBundleError.unsupportedHost("the VM's hardware model is not supported by this Mac.")
        }
        return model
    }

    public func machineIdentifier() throws -> VZMacMachineIdentifier {
        guard let data = FileManager.default.contents(atPath: machineIdentifierURL.path) else {
            throw VMBundleError.missing("machine identifier")
        }
        guard let id = VZMacMachineIdentifier(dataRepresentation: data) else {
            throw VMBundleError.corrupt("machine-identifier.bin")
        }
        return id
    }

    public func auxiliaryStorage() throws -> VZMacAuxiliaryStorage {
        guard FileManager.default.fileExists(atPath: auxiliaryStorageURL.path) else {
            throw VMBundleError.missing("auxiliary storage")
        }
        return VZMacAuxiliaryStorage(url: auxiliaryStorageURL)
    }

    /// Creates a fresh bundle for the given restore image configuration. Overwrites nothing: the
    /// directory must not contain a VM yet.
    public static func create(at url: URL, requirements: VZMacOSConfigurationRequirements,
                              settings: VMSettings) throws -> VMBundle {
        let fm = FileManager.default
        let bundle = VMBundle(url: url)
        if bundle.exists { throw VMBundleError.corrupt("folder (a workspace exists already)") }
        try fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

        guard requirements.hardwareModel.isSupported else {
            throw VMBundleError.unsupportedHost("the macOS version needs a newer Mac.")
        }
        var settings = settings
        settings.cpuCount = max(settings.cpuCount, requirements.minimumSupportedCPUCount)
        settings.memoryMiB = max(settings.memoryMiB, requirements.minimumSupportedMemorySize / (1024 * 1024))

        try requirements.hardwareModel.dataRepresentation.write(to: bundle.hardwareModelURL)
        try VZMacMachineIdentifier().dataRepresentation.write(to: bundle.machineIdentifierURL)
        _ = try VZMacAuxiliaryStorage(creatingStorageAt: bundle.auxiliaryStorageURL,
                                      hardwareModel: requirements.hardwareModel, options: [])
        try DiskImage.createSparse(at: bundle.diskURL, gibibytes: settings.diskGiB)

        let state = VMState(settings: settings, macAddress: VZMACAddress.randomLocallyAdministered().string,
                            createdAt: Date(), guestBuild: nil, guestVersion: nil,
                            provisioned: false, bootstrapped: false, screenSharingReady: false)
        try bundle.saveState(state)
        return bundle
    }
}

enum DiskImage {
    /// A raw disk image as a sparse file: it takes only the space the guest actually writes.
    static func createSparse(at url: URL, gibibytes: UInt64) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil,
                                             attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: gibibytes * 1024 * 1024 * 1024)
    }
}
