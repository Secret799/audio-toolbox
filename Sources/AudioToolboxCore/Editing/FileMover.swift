import Foundation

public enum FileMoveOutcome: Equatable, Sendable {
    case moved(URL)
    case alreadyAtDestination(URL)
}

public enum FileMoveError: LocalizedError, Equatable, Sendable {
    case destinationExists(URL)
    case destinationUnavailable(URL)
    case moveFailed(source: URL, destination: URL, reason: String)

    public var errorDescription: String? {
        switch self {
        case let .destinationExists(url):
            "目标目录已存在同名文件：\(url.lastPathComponent)"
        case let .destinationUnavailable(url):
            "目标目录不可用：\(url.path)"
        case let .moveFailed(_, destination, reason):
            "无法移动到 \(destination.path)：\(reason)"
        }
    }
}

public protocol FileMoving: Sendable {
    func move(
        _ sourceURL: URL,
        to destinationDirectory: URL
    ) async throws -> FileMoveOutcome
}

public struct FoundationFileMover: FileMoving {
    public init() {}

    public func move(
        _ sourceURL: URL,
        to destinationDirectory: URL
    ) async throws -> FileMoveOutcome {
        let fileManager = FileManager.default
        let source = sourceURL.standardizedFileURL
        let directory = destinationDirectory.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(
            atPath: directory.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            throw FileMoveError.destinationUnavailable(directory)
        }

        let destination = directory.appendingPathComponent(source.lastPathComponent)
        guard source != destination else {
            return .alreadyAtDestination(source)
        }
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw FileMoveError.destinationExists(destination)
        }

        do {
            try fileManager.moveItem(at: source, to: destination)
            return .moved(destination)
        } catch {
            if (error as? CocoaError)?.code == .fileWriteFileExists {
                throw FileMoveError.destinationExists(destination)
            }
            throw FileMoveError.moveFailed(
                source: source,
                destination: destination,
                reason: error.localizedDescription
            )
        }
    }
}
