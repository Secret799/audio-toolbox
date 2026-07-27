import Foundation

public struct MetadataPatch: Equatable, Sendable {
    public let artist: String?
    public let album: String?
    public let composer: String?

    public init(artist: String?, album: String?, composer: String? = nil) {
        self.artist = artist?.trimmedNonEmpty
        self.album = album?.trimmedNonEmpty
        self.composer = composer?.trimmedNonEmpty
    }

    public static func validated(
        artist: String?,
        album: String?,
        composer: String? = nil
    ) -> MetadataPatch? {
        let patch = MetadataPatch(
            artist: artist,
            album: album,
            composer: composer
        )
        return patch.artist == nil && patch.album == nil && patch.composer == nil
            ? nil
            : patch
    }
}

public struct BatchEditTarget: Equatable, Sendable {
    public let url: URL
    public let fileIdentity: FileIdentity
    public let fileSize: Int64
    public let modificationDate: Date

    public init(
        url: URL,
        fileIdentity: FileIdentity,
        fileSize: Int64,
        modificationDate: Date
    ) {
        self.url = url
        self.fileIdentity = fileIdentity
        self.fileSize = fileSize
        self.modificationDate = modificationDate
    }

    func matches(_ fingerprint: StableFileFingerprint) -> Bool {
        fileIdentity == fingerprint.fileIdentity
            && fileSize == fingerprint.fileSize
            && modificationDate == fingerprint.modificationDate
    }
}

public struct BatchEditOperation: Equatable, Sendable {
    public let target: BatchEditTarget
    public let patch: MetadataPatch

    public init(target: BatchEditTarget, patch: MetadataPatch) {
        self.target = target
        self.patch = patch
    }
}

public struct BatchMigrationConfiguration: Equatable, Sendable {
    public let destinationDirectory: URL

    public init(destinationDirectory: URL) {
        self.destinationDirectory = destinationDirectory
    }
}

public struct BatchEditRequest: Sendable {
    public let operations: [BatchEditOperation]
    public let migration: BatchMigrationConfiguration?

    public var targets: [BatchEditTarget] {
        operations.map(\.target)
    }

    public init(
        operations: [BatchEditOperation],
        migration: BatchMigrationConfiguration? = nil
    ) {
        self.operations = operations
        self.migration = migration
    }

    public init(
        targets: [BatchEditTarget],
        patch: MetadataPatch,
        migration: BatchMigrationConfiguration? = nil
    ) {
        operations = targets.map { BatchEditOperation(target: $0, patch: patch) }
        self.migration = migration
    }
}

public enum BatchFileStatus: Equatable, Sendable {
    case succeeded, failed, notProcessed
}

public enum BatchMigrationStatus: Equatable, Sendable {
    case notRequested
    case moved
    case alreadyAtDestination
    case skippedConflict
    case failed
}

public struct BatchFileResult: Equatable, Sendable {
    public let url: URL
    public let status: BatchFileStatus
    public let message: String?
    public let recoveryURL: URL?
    public let finalURL: URL
    public let migrationStatus: BatchMigrationStatus

    public init(
        url: URL,
        status: BatchFileStatus,
        message: String?,
        recoveryURL: URL? = nil,
        finalURL: URL? = nil,
        migrationStatus: BatchMigrationStatus = .notRequested
    ) {
        self.url = url
        self.status = status
        self.message = message
        self.recoveryURL = recoveryURL
        self.finalURL = finalURL ?? url
        self.migrationStatus = migrationStatus
    }

    public var isSucceededWithWarning: Bool {
        status == .succeeded && message?.trimmedNonEmpty != nil
    }
}

public struct BatchEditSummary: Equatable, Sendable {
    public let results: [BatchFileResult]

    public init(results: [BatchFileResult]) {
        self.results = results
    }

    public var succeededCount: Int {
        results.count { $0.status == .succeeded }
    }

    public var failedCount: Int {
        results.count { $0.status == .failed }
    }

    public var notProcessedCount: Int {
        results.count { $0.status == .notProcessed }
    }

    public var cleanSucceededResults: [BatchFileResult] {
        results.filter { $0.status == .succeeded && !$0.isSucceededWithWarning }
    }

    public var cleanSucceededCount: Int {
        cleanSucceededResults.count
    }

    public var succeededWithWarnings: [BatchFileResult] {
        results.filter(\.isSucceededWithWarning)
    }

    public var succeededWithWarningCount: Int {
        succeededWithWarnings.count
    }

    public var movedCount: Int {
        results.count { $0.migrationStatus == .moved }
    }
}
