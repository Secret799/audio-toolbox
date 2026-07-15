import Darwin
import Foundation

struct StableFileFingerprint: Equatable, Sendable {
    let fileIdentity: FileIdentity
    let fileSize: Int64
    let modificationDate: Date
}

enum StableFileIdentityResolver {
    static let resourceKeys: Set<URLResourceKey> = [
        .fileSizeKey,
        .contentModificationDateKey,
        .fileResourceIdentifierKey,
        .volumeIdentifierKey,
    ]

    static func fingerprint(for url: URL) throws -> StableFileFingerprint {
        // Recreate the URL to avoid NSURL resource-value caches surviving a
        // path replacement between scan and execution.
        let freshURL = URL(fileURLWithPath: url.path, isDirectory: false)
        let values = try freshURL.resourceValues(forKeys: resourceKeys)
        guard let fileSize = values.fileSize,
              let modificationDate = values.contentModificationDate
        else {
            throw CocoaError(.fileReadUnknown)
        }
        return StableFileFingerprint(
            fileIdentity: fileIdentity(
                for: freshURL,
                fileResourceIdentifier: values.fileResourceIdentifier,
                volumeIdentifier: values.volumeIdentifier,
                usePOSIXFallback: true
            ),
            fileSize: Int64(fileSize),
            modificationDate: modificationDate
        )
    }

    static func fileIdentity(
        for url: URL,
        fileResourceIdentifier: Any?,
        volumeIdentifier: Any?,
        usePOSIXFallback: Bool = false
    ) -> FileIdentity {
        if let volume = archivedIdentifier(volumeIdentifier),
           let file = archivedIdentifier(fileResourceIdentifier)
        {
            return FileIdentity(rawValue: "resource:\(volume):\(file)")
        }

        if usePOSIXFallback,
           let identity = posixIdentity(for: url)
        {
            return identity
        }

        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        return FileIdentity(rawValue: "path:\(path)")
    }

    private static func archivedIdentifier(_ identifier: Any?) -> String? {
        guard let identifier = identifier as? any NSSecureCoding else { return nil }

        do {
            let data = try NSKeyedArchiver.archivedData(
                withRootObject: identifier,
                requiringSecureCoding: true
            )
            return data.base64EncodedString()
        } catch {
            return nil
        }
    }

    private static func posixIdentity(for url: URL) -> FileIdentity? {
        var status = stat()
        guard url.path.withCString({ lstat($0, &status) }) == 0 else { return nil }
        return FileIdentity(rawValue: "posix:\(UInt64(status.st_dev)):\(UInt64(status.st_ino))")
    }
}
