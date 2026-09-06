import Foundation
import SwiftData

/// Version 1 of the on-disk schema.
///
/// Declaring the schema explicitly — rather than handing `ModelContainer` a
/// bare list of types — is what makes a future model change a *migration*
/// rather than a corrupt store. When a property is added or renamed, add a
/// `GrokboxSchemaV2` and a stage in `GrokboxMigrationPlan`; SwiftData can then
/// carry existing installs forward instead of failing to open.
public enum GrokboxSchemaV1: VersionedSchema {
    public static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }
    public static var models: [any PersistentModel.Type] {
        [MailAccount.self, MessageHeader.self, ContactedAddress.self, CleanupAction.self,
         SenderRule.self, MailboxSnapshot.self, SenderProfile.self, InboxDigest.self]
    }
}

public enum GrokboxMigrationPlan: SchemaMigrationPlan {
    public static var schemas: [any VersionedSchema.Type] { [GrokboxSchemaV1.self] }
    /// Empty until a V2 exists. Each future stage goes here, in order.
    public static var stages: [MigrationStage] { [] }
}

/// Opens the local index, and survives failing to.
///
/// The previous behaviour was `fatalError` on any open failure, which turns a
/// recoverable problem — a half-written store, a schema the running build no
/// longer understands, a full disk — into an app that cannot launch at all and
/// cannot even be reset from inside itself. This tries three things in order and
/// always returns something usable.
public enum GrokboxStore {
    public struct Opened: Sendable {
        public let container: ModelContainer
        /// Non-nil when the store could not be opened as-is. The UI shows this;
        /// it is the only honest way to tell someone their index was rebuilt.
        public let recovery: String?
        /// True when nothing could be persisted and this session is memory-only.
        public let isEphemeral: Bool
    }

    public static func open(inMemory: Bool = false) -> Opened {
        let schema = Schema(versionedSchema: GrokboxSchemaV1.self)

        if inMemory {
            let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            // A memory-only container cannot fail for disk reasons; if it does,
            // there is no fallback left and crashing is honest.
            return Opened(container: try! ModelContainer(for: schema, migrationPlan: GrokboxMigrationPlan.self,
                                                         configurations: config),
                          recovery: nil, isEphemeral: true)
        }

        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        // 1. The normal path.
        if let container = try? ModelContainer(for: schema, migrationPlan: GrokboxMigrationPlan.self,
                                               configurations: config) {
            return Opened(container: container, recovery: nil, isEphemeral: false)
        }

        // 2. Move the unreadable store aside and start a fresh one. Nothing is
        //    deleted — the old files are kept next to the new store so they can
        //    be inspected or recovered by hand.
        let moved = archiveExistingStore()
        if let container = try? ModelContainer(for: schema, migrationPlan: GrokboxMigrationPlan.self,
                                               configurations: config) {
            return Opened(
                container: container,
                recovery: moved
                    ? "Grokbox could not read its index, so it started a new one. Your mail is untouched — re-index to rebuild. The old index was kept alongside it."
                    : "Grokbox could not read its index and started a new one. Re-index to rebuild.",
                isEphemeral: false)
        }

        // 3. Nothing can be written. Run in memory so the app still opens and can
        //    explain itself.
        let memory = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try! ModelContainer(for: schema, migrationPlan: GrokboxMigrationPlan.self,
                                            configurations: memory)
        return Opened(
            container: container,
            recovery: "Grokbox cannot write to its container, so nothing will be saved this session. Check disk space and permissions.",
            isEphemeral: true)
    }

    /// Where SwiftData puts the default store inside the sandbox.
    static var storeURL: URL? {
        try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                     appropriateFor: nil, create: false)
            .appending(path: "default.store")
    }

    @discardableResult
    static func archiveExistingStore() -> Bool {
        guard let store = storeURL else { return false }
        let fm = FileManager.default
        guard fm.fileExists(atPath: store.path) else { return false }
        // A stable suffix, so repeated failures overwrite one backup rather than
        // filling the container with copies.
        var moved = false
        for suffix in ["", "-shm", "-wal"] {
            let from = URL(fileURLWithPath: store.path + suffix)
            let to = URL(fileURLWithPath: store.path + suffix + ".unreadable")
            guard fm.fileExists(atPath: from.path) else { continue }
            try? fm.removeItem(at: to)
            if (try? fm.moveItem(at: from, to: to)) != nil { moved = true }
        }
        return moved
    }
}
