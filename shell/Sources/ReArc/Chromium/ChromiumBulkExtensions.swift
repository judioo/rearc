#if REARC_CHROMIUM
import Foundation
import ReArcEngine
import SidebarModel

private final class BulkExtensionReply {
    let items: [ExtensionReinstallQueue.Item]
    let completion: (ExtensionReinstallQueue.Item, Int32, String, Bool) -> Void
    init(_ items: [ExtensionReinstallQueue.Item], _ completion: @escaping (ExtensionReinstallQueue.Item, Int32, String, Bool) -> Void) {
        self.items = items
        self.completion = completion
    }
}

private let bulkExtensionReply: ReArcExtensionInstallCallback = { context, id, status, reason, completed, total in
    guard let context else { return }
    let box = Unmanaged<BulkExtensionReply>.fromOpaque(context).takeUnretainedValue()
    let key = id.map { String(cString: $0) } ?? ""
    let error = reason.map { String(cString: $0) } ?? ""
    let item = box.items.first { $0.id == key } ?? box.items[0]
    let done = completed == total
    MainActor.assumeIsolated { box.completion(item, status, error, done) }
    if done { Unmanaged<BulkExtensionReply>.fromOpaque(context).release() }
}

extension ChromiumRuntime {
    var supportsBulkExtensionInstall: Bool {
        isReady && !isStopping && capabilities.extensionBulkInstall &&
        dlsym(UnsafeMutableRawPointer(bitPattern: -2), "ReArcProfileInstallExtensions") != nil
    }

    func installExtensions(_ items: [ExtensionReinstallQueue.Item],
                           completion: @escaping (ExtensionReinstallQueue.Item, Int32, String, Bool) -> Void) {
        guard let first = items.first else { return }
        guard items.allSatisfy({ $0.origin == .webStore && $0.profileID == first.profileID }) else {
            for (index, item) in items.enumerated() {
                completion(item, 4, "Only Chrome Web Store extensions can be imported automatically.", index == items.count - 1)
            }
            return
        }
        withEngineProfile(.persistent(first.profileID)) { [self] profile in
            guard supportsBulkExtensionInstall, let profile else {
                for (index, item) in items.enumerated() {
                    completion(item, 3, "The extension installer is unavailable.", index == items.count - 1)
                }
                return
            }
            let context = Unmanaged.passRetained(BulkExtensionReply(items, completion)).toOpaque()
            let status: ReArcStatus
            switch first.origin {
            case .webStore:
                typealias Install = @convention(c) (UInt64, UnsafePointer<UnsafePointer<CChar>?>?, UInt32, ReArcExtensionInstallCallback?, UnsafeMutableRawPointer?) -> ReArcStatus
                let install = unsafeBitCast(dlsym(UnsafeMutableRawPointer(bitPattern: -2), "ReArcProfileInstallExtensions")!, to: Install.self)
                let strings = items.map { strdup($0.id)! }
                defer { strings.forEach { free($0) } }
                let pointers = strings.map { Optional(UnsafePointer<CChar>($0)) }
                status = pointers.withUnsafeBufferPointer { install(profile, $0.baseAddress, UInt32(items.count), bulkExtensionReply, context) }
            case .unpacked, .other:
                status = ReArcStatus(REARC_INVALID_ARGUMENT)
            }
            if status != REARC_OK {
                Unmanaged<BulkExtensionReply>.fromOpaque(context).release()
                for (index, item) in items.enumerated() {
                    completion(item, 3, "Could not start installation: \(status.rearcName)", index == items.count - 1)
                }
            }
        }
    }
}
#endif
