import Foundation

public protocol DirectoryBookmarkResolving: Sendable {
    func bookmarkData(for url: URL) throws -> Data
    func resolve(_ data: Data) throws -> (url: URL, isStale: Bool)
}

public struct FoundationDirectoryBookmarkResolver: DirectoryBookmarkResolving {
    public init() {}

    public func bookmarkData(for url: URL) throws -> Data {
        try url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    public func resolve(_ data: Data) throws -> (url: URL, isStale: Bool) {
        var isStale = false
        let url = try URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        return (url, isStale)
    }
}

public final class SecurityScopedDirectoryStore: @unchecked Sendable {
    private static let bookmarkKey = "audioToolbox.lastDirectoryBookmark"

    private let defaults: UserDefaults
    private let resolver: any DirectoryBookmarkResolving
    private let lock = NSLock()

    public init(
        defaults: UserDefaults = .standard,
        resolver: any DirectoryBookmarkResolving = FoundationDirectoryBookmarkResolver()
    ) {
        self.defaults = defaults
        self.resolver = resolver
    }

    public func save(url: URL) throws {
        try lock.withLock {
            let data = try resolver.bookmarkData(for: url)
            defaults.set(data, forKey: Self.bookmarkKey)
        }
    }

    public func restore() throws -> URL? {
        try lock.withLock {
            guard let storedValue = defaults.object(forKey: Self.bookmarkKey) else {
                return nil
            }
            guard let data = storedValue as? Data else {
                defaults.removeObject(forKey: Self.bookmarkKey)
                return nil
            }

            let resolution: (url: URL, isStale: Bool)
            do {
                resolution = try resolver.resolve(data)
            } catch {
                defaults.removeObject(forKey: Self.bookmarkKey)
                return nil
            }

            if resolution.isStale {
                let refreshedData = try resolver.bookmarkData(for: resolution.url)
                defaults.set(refreshedData, forKey: Self.bookmarkKey)
            }

            return resolution.url
        }
    }
}

public protocol SecurityScopedResourceAccessing: Sendable {
    func start(_ url: URL) -> Bool
    func stop(_ url: URL)
}

public struct FoundationSecurityScopedResourceAccessor: SecurityScopedResourceAccessing {
    public init() {}

    public func start(_ url: URL) -> Bool {
        url.startAccessingSecurityScopedResource()
    }

    public func stop(_ url: URL) {
        url.stopAccessingSecurityScopedResource()
    }
}

public final class SecurityScopedAccessLease: @unchecked Sendable {
    public let url: URL

    private let accessor: any SecurityScopedResourceAccessing
    private let didStart: Bool

    public init(
        url: URL,
        accessor: any SecurityScopedResourceAccessing = FoundationSecurityScopedResourceAccessor()
    ) {
        self.url = url
        self.accessor = accessor
        self.didStart = accessor.start(url)
    }

    deinit {
        if didStart {
            accessor.stop(url)
        }
    }
}
