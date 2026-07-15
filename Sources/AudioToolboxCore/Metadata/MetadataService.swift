import Foundation

public protocol MetadataService: Sendable {
    func read(url: URL) async throws -> AudioMetadata
    func canWrite(url: URL) async -> Bool
    func write(url: URL, patch: MetadataPatch) async throws
}

public enum MetadataServiceError: Error, Equatable, Sendable {
    case unreadable(String)
    case unsupported(String)
    case notWritable(String)
    case saveFailed(String)
    case verificationFailed(String)
}
