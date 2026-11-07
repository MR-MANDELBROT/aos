import AOSKit
import DiskArbitration
import Foundation
import IOKit

/// Keeps the workspace's attached disk out of everyone's reach (see WorkspaceCustody.swift). The helper attaches it
/// without mounting, but macOS lets an administrator on the console mount any attached volume (Disk Arbitration,
/// system.volume.*.mount: is-admin or on-console). Disk Arbitration asks every registered approval session before it
/// mounts, unmounts or ejects: this one refuses anything on the guarded disks and in the APFS containers inside them,
/// and, while a disk is being attached, every disk image's volumes. Ejecting is allowed only when the helper itself
/// detaches. Lives as long as the helper (which doesn't exit while a disk is attached).
final class DiskGuard: DiskGuarding, @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.marquart.aos.powerd.diskguard")
    private let session: DASession
    private var guarded = Set<String>()
    private var attaching = false
    private var ejectAllowed = Set<String>()
    var log: (String) -> Void = { _ in }

    init?() {
        guard let session = DASessionCreate(kCFAllocatorDefault) else { return nil }
        self.session = session
        let context = Unmanaged.passUnretained(self).toOpaque()
        DARegisterDiskMountApprovalCallback(session, nil, { disk, context in
            guard let context else { return nil }
            let me = Unmanaged<DiskGuard>.fromOpaque(context).takeUnretainedValue()
            return me.refuse(disk, what: "mount")
        }, context)
        DARegisterDiskUnmountApprovalCallback(session, nil, { disk, context in
            guard let context else { return nil }
            let me = Unmanaged<DiskGuard>.fromOpaque(context).takeUnretainedValue()
            return me.refuse(disk, what: "unmount", unlessEjectAllowed: true)
        }, context)
        DARegisterDiskEjectApprovalCallback(session, nil, { disk, context in
            guard let context else { return nil }
            let me = Unmanaged<DiskGuard>.fromOpaque(context).takeUnretainedValue()
            return me.refuse(disk, what: "eject", unlessEjectAllowed: true)
        }, context)
        DASessionSetDispatchQueue(session, queue)
    }

    func guardDisks(_ names: Set<String>) {
        queue.sync {
            guarded = names
            ejectAllowed.formIntersection(names)
        }
    }

    func setAttaching(_ value: Bool) { queue.sync { attaching = value } }

    func allowEject(_ name: String) { queue.sync { _ = ejectAllowed.insert(name) } }

    /// Runs on `queue` (Disk Arbitration calls back there).
    private func refuse(_ disk: DADisk, what: String, unlessEjectAllowed: Bool = false) -> Unmanaged<DADissenter>? {
        let chain = Self.wholeDisks(above: disk)
        let ours = chain.first { guarded.contains($0) }
        var refuse = ours != nil
        if refuse, unlessEjectAllowed, let ours, ejectAllowed.contains(ours) { refuse = false }
        if !refuse, attaching, what == "mount", Self.isDiskImage(disk) { refuse = true }
        guard refuse else { return nil }
        let name = DADiskGetBSDName(disk).map { String(cString: $0) } ?? "?"
        log("workspace disk: refused to \(what) \(name)")
        let text = "The disk of the \(Brand.name) workspace is in use." as CFString
        return Unmanaged.passRetained(DADissenterCreate(kCFAllocatorDefault, DAReturn(Self.notPermitted), text))
    }

    /// kDAReturnNotPermitted (err_local | err_local_diskarbitration | 0x0D).
    static let notPermitted = Int32(bitPattern: 0xF8DA000D)

    /// The whole disks ("disk10") the disk lives on, following the device tree up: a volume in an APFS container
    /// leads to the container's disk and from there to the partition and the disk the container sits on.
    static func wholeDisks(above disk: DADisk) -> [String] {
        let media = DADiskCopyIOMedia(disk)
        guard media != 0 else { return [] }
        var names: [String] = []
        var entry: io_registry_entry_t = media
        var depth = 0
        while entry != 0 && depth < 32 {
            if let bsd = IORegistryEntryCreateCFProperty(entry, "BSD Name" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String, let whole = wholeName(bsd), names.last != whole {
                names.append(whole)
            }
            var parent: io_registry_entry_t = 0
            let kr = IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent)
            IOObjectRelease(entry)
            entry = kr == KERN_SUCCESS ? parent : 0
            depth += 1
        }
        if entry != 0 { IOObjectRelease(entry) }
        return names
    }

    /// "disk10s2" -> "disk10".
    static func wholeName(_ bsd: String) -> String? {
        guard let match = bsd.range(of: #"^disk[0-9]+"#, options: .regularExpression) else { return nil }
        return String(bsd[match])
    }

    static func isDiskImage(_ disk: DADisk) -> Bool {
        guard let description = DADiskCopyDescription(disk) as? [String: Any] else { return false }
        let model = (description[kDADiskDescriptionDeviceModelKey as String] as? String) ?? ""
        return model.localizedCaseInsensitiveContains("disk image")
    }
}
