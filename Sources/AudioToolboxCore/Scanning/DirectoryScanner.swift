import Foundation

public enum ScanEvent: Equatable, Sendable {
    case discovered(Int)
    case loaded(AudioTrack)
    case failed(URL, String)
    case finished
}

public protocol DirectoryScanning: Sendable {
    func scan(root: URL) -> AsyncStream<ScanEvent>
}

public struct DirectoryScanner: DirectoryScanning {
    private static let resourceKeys: Set<URLResourceKey> = [
        .isRegularFileKey,
        .isDirectoryKey,
        .isHiddenKey,
        .isSymbolicLinkKey,
        .fileSizeKey,
        .fileResourceIdentifierKey,
    ]

    private let metadataService: any MetadataService

    public init(metadataService: any MetadataService) {
        self.metadataService = metadataService
    }

    public func scan(root: URL) -> AsyncStream<ScanEvent> {
        AsyncStream { continuation in
            let task = Task {
                await scan(root: root, continuation: continuation)
            }
            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    private func scan(
        root: URL,
        continuation: AsyncStream<ScanEvent>.Continuation
    ) async {
        defer {
            continuation.yield(.finished)
            continuation.finish()
        }

        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: Array(Self.resourceKeys),
            options: [],
            errorHandler: { url, error in
                continuation.yield(.failed(url, String(describing: error)))
                return true
            }
        ) else {
            continuation.yield(.failed(root, "Unable to enumerate directory"))
            return
        }

        var discovered = 0
        var identities: Set<FileIdentity> = []

        while let url = enumerator.nextObject() as? URL {
            guard !Task.isCancelled else { return }

            let values: URLResourceValues
            do {
                values = try url.resourceValues(forKeys: Self.resourceKeys)
            } catch {
                continuation.yield(.failed(url, String(describing: error)))
                continue
            }

            if AudioFileCandidate.shouldSkip(url, values: values) {
                if values.isDirectory == true || values.isSymbolicLink == true {
                    enumerator.skipDescendants()
                }
                continue
            }

            guard values.isDirectory != true,
                  values.isRegularFile == true,
                  let format = AudioFileCandidate.format(for: url)
            else {
                continue
            }

            let identity = Self.fileIdentity(for: url, values: values)
            guard identities.insert(identity).inserted else { continue }

            discovered += 1
            continuation.yield(.discovered(discovered))

            do {
                let metadata = try await metadataService.read(url: url)
                guard !Task.isCancelled else { return }

                let isWritable = await metadataService.canWrite(url: url)
                guard !Task.isCancelled else { return }

                continuation.yield(
                    .loaded(
                        AudioTrack(
                            id: identity,
                            url: url,
                            format: format,
                            metadata: metadata,
                            fileSize: Int64(values.fileSize ?? 0),
                            isWritable: isWritable,
                            issue: nil
                        )
                    )
                )
            } catch is CancellationError where Task.isCancelled {
                return
            } catch {
                continuation.yield(.failed(url, String(describing: error)))
            }
        }
    }

    private static func fileIdentity(for url: URL, values: URLResourceValues) -> FileIdentity {
        if let resourceIdentifier = values.fileResourceIdentifier {
            return FileIdentity(rawValue: "resource:\(String(describing: resourceIdentifier))")
        }

        return FileIdentity(rawValue: "path:\(url.standardizedFileURL.path)")
    }
}
