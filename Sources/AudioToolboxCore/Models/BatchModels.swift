import Foundation

public struct MetadataPatch: Equatable, Sendable {
    public let artist: String?
    public let album: String?

    public init(artist: String?, album: String?) {
        self.artist = artist?.trimmedNonEmpty
        self.album = album?.trimmedNonEmpty
    }

    public static func validated(artist: String?, album: String?) -> MetadataPatch? {
        let patch = MetadataPatch(artist: artist, album: album)
        return patch.artist == nil && patch.album == nil ? nil : patch
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

public struct BatchEditRequest: Sendable {
    public let targets: [BatchEditTarget]
    public let patch: MetadataPatch

    public init(targets: [BatchEditTarget], patch: MetadataPatch) {
        self.targets = targets
        self.patch = patch
    }
}

public enum BatchFileStatus: Equatable, Sendable {
    case succeeded, failed, notProcessed
}

public struct BatchFileResult: Equatable, Sendable {
    public let url: URL
    public let status: BatchFileStatus
    public let message: String?
    public let recoveryURL: URL?

    public init(
        url: URL,
        status: BatchFileStatus,
        message: String?,
        recoveryURL: URL? = nil
    ) {
        self.url = url
        self.status = status
        self.message = message
        self.recoveryURL = recoveryURL
    }

    public var isSucceededWithWarning: Bool {
        status == .succeeded && message?.trimmedNonEmpty != nil
    }
}

public struct BatchEditSummary: Equatable, Sendable {
    public let results: [BatchFileResult]

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
}
