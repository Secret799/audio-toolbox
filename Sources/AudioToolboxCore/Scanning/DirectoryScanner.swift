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

protocol ScanningDirectoryEnumerator: AnyObject {
    func nextObject() -> Any?
    func skipDescendants()
}

extension FileManager.DirectoryEnumerator: ScanningDirectoryEnumerator {}

typealias DirectoryEnumeratorFactory = @Sendable (
    _ root: URL,
    _ prefetchedKeys: [URLResourceKey],
    _ errorHandler: @escaping @Sendable (URL, Error) -> Bool
) -> (any ScanningDirectoryEnumerator)?

typealias ResourceValuesReader = @Sendable (
    _ url: URL,
    _ keys: Set<URLResourceKey>
) throws -> URLResourceValues

public struct DirectoryScanner: DirectoryScanning {
    static let enumerationOptions: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles]

    private static let traversalKeys: Set<URLResourceKey> = [
        .isRegularFileKey,
        .isDirectoryKey,
        .isHiddenKey,
        .isSymbolicLinkKey,
    ]

    private static let detailKeys: Set<URLResourceKey> = [
        .fileSizeKey,
        .contentModificationDateKey,
        .fileResourceIdentifierKey,
        .volumeIdentifierKey,
    ]

    private let metadataService: any MetadataService
    private let makeEnumerator: DirectoryEnumeratorFactory
    private let readResourceValues: ResourceValuesReader
    private let iterationBoundary: @Sendable () -> Void

    public init(metadataService: any MetadataService) {
        self.init(
            metadataService: metadataService,
            makeEnumerator: { root, keys, errorHandler in
                FileManager.default.enumerator(
                    at: root,
                    includingPropertiesForKeys: keys,
                    options: DirectoryScanner.enumerationOptions,
                    errorHandler: errorHandler
                )
            },
            readResourceValues: { url, keys in
                try url.resourceValues(forKeys: keys)
            }
        )
    }

    init(
        metadataService: any MetadataService,
        makeEnumerator: @escaping DirectoryEnumeratorFactory,
        readResourceValues: @escaping ResourceValuesReader,
        iterationBoundary: @escaping @Sendable () -> Void = {}
    ) {
        self.metadataService = metadataService
        self.makeEnumerator = makeEnumerator
        self.readResourceValues = readResourceValues
        self.iterationBoundary = iterationBoundary
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

        guard let enumerator = makeEnumerator(
            root,
            Array(Self.traversalKeys),
            { url, error in
                continuation.yield(.failed(url, String(describing: error)))
                return true
            }
        ) else {
            continuation.yield(.failed(root, "Unable to enumerate directory"))
            return
        }

        var discovered = 0
        var identities: Set<FileIdentity> = []

        while !Task.isCancelled {
            guard let url = enumerator.nextObject() as? URL else { break }
            guard !Task.isCancelled else { break }

            let traversalValues: URLResourceValues
            do {
                traversalValues = try readResourceValues(url, Self.traversalKeys)
            } catch {
                continuation.yield(.failed(url, String(describing: error)))
                continue
            }

            if AudioFileCandidate.shouldSkip(url, values: traversalValues) {
                if traversalValues.isDirectory == true {
                    enumerator.skipDescendants()
                }
                continue
            }

            guard traversalValues.isDirectory != true,
                  traversalValues.isRegularFile == true,
                  let format = AudioFileCandidate.format(for: url)
            else {
                continue
            }

            let detailValues = try? readResourceValues(url, Self.detailKeys)
            let identity = StableFileIdentityResolver.fileIdentity(
                for: url,
                fileResourceIdentifier: detailValues?.fileResourceIdentifier,
                volumeIdentifier: detailValues?.volumeIdentifier,
                usePOSIXFallback: detailValues != nil
            )
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
                            fileSize: Int64(detailValues?.fileSize ?? 0),
                            modificationDate: detailValues?.contentModificationDate ?? .distantPast,
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

            iterationBoundary()
        }
    }

    static func fileIdentity(
        for url: URL,
        fileResourceIdentifier: Any?,
        volumeIdentifier: Any?
    ) -> FileIdentity {
        StableFileIdentityResolver.fileIdentity(
            for: url,
            fileResourceIdentifier: fileResourceIdentifier,
            volumeIdentifier: volumeIdentifier
        )
    }

}
