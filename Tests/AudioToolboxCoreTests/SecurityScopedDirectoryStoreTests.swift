import Foundation
import Testing
@testable import AudioToolboxCore

@Suite("SecurityScopedDirectoryStoreTests")
struct SecurityScopedDirectoryStoreTests {
    @Test("保存与恢复使用固定的安全作用域书签键")
    func saveAndRestoreUsesFixedBookmarkKey() throws {
        let directoryURL = URL(fileURLWithPath: "/tmp/audio-toolbox-bookmark-test")
        let bookmarkData = Data("bookmark".utf8)
        let resolver = FakeBookmarkResolver(
            bookmarkDataResults: [.success(bookmarkData)],
            resolveResults: [.success((directoryURL, false))]
        )
        let defaults = makeDefaults()
        let store = SecurityScopedDirectoryStore(defaults: defaults, resolver: resolver)

        try store.save(url: directoryURL)
        let restoredURL = try store.restore()

        #expect(restoredURL == directoryURL)
        #expect(defaults.data(forKey: "audioToolbox.lastDirectoryBookmark") == bookmarkData)
        #expect(resolver.bookmarkURLs == [directoryURL])
        #expect(resolver.resolvedData == [bookmarkData])
    }

    @Test("陈旧书签使用解析后的 URL 自动重存")
    func staleBookmarkIsAutomaticallyRecreated() throws {
        let originalURL = URL(fileURLWithPath: "/tmp/original-audio-directory")
        let resolvedURL = URL(fileURLWithPath: "/tmp/moved-audio-directory")
        let originalData = Data("original-bookmark".utf8)
        let refreshedData = Data("refreshed-bookmark".utf8)
        let resolver = FakeBookmarkResolver(
            bookmarkDataResults: [.success(originalData), .success(refreshedData)],
            resolveResults: [.success((resolvedURL, true))]
        )
        let defaults = makeDefaults()
        let store = SecurityScopedDirectoryStore(defaults: defaults, resolver: resolver)

        try store.save(url: originalURL)
        let restoredURL = try store.restore()

        #expect(restoredURL == resolvedURL)
        #expect(defaults.data(forKey: "audioToolbox.lastDirectoryBookmark") == refreshedData)
        #expect(resolver.bookmarkURLs == [originalURL, resolvedURL])
        #expect(resolver.resolvedData == [originalData])
    }

    @Test("损坏书签会被清除并返回 nil")
    func corruptBookmarkIsCleared() throws {
        let corruptData = Data("not-a-bookmark".utf8)
        let resolver = FakeBookmarkResolver(
            resolveResults: [.failure(FakeBookmarkError.corrupt)]
        )
        let defaults = makeDefaults()
        defaults.set(corruptData, forKey: "audioToolbox.lastDirectoryBookmark")
        let store = SecurityScopedDirectoryStore(defaults: defaults, resolver: resolver)

        let restoredURL = try store.restore()

        #expect(restoredURL == nil)
        #expect(defaults.object(forKey: "audioToolbox.lastDirectoryBookmark") == nil)
        #expect(resolver.resolvedData == [corruptData])
    }

    @Test("非 Data 的损坏值也会被清除")
    func invalidStoredValueIsCleared() throws {
        let defaults = makeDefaults()
        defaults.set("invalid", forKey: "audioToolbox.lastDirectoryBookmark")
        let resolver = FakeBookmarkResolver()
        let store = SecurityScopedDirectoryStore(defaults: defaults, resolver: resolver)

        #expect(try store.restore() == nil)
        #expect(defaults.object(forKey: "audioToolbox.lastDirectoryBookmark") == nil)
        #expect(resolver.resolvedData.isEmpty)
    }

    @Test("store 可安全地跨并发任务共享")
    func storeCanBeSharedAcrossConcurrentTasks() async {
        let directoryURL = URL(fileURLWithPath: "/tmp/concurrent-bookmark-store")
        let defaults = makeDefaults()
        let store = SecurityScopedDirectoryStore(
            defaults: defaults,
            resolver: IdentityBookmarkResolver()
        )

        let allOperationsSucceeded = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<64 {
                group.addTask {
                    do {
                        try store.save(url: directoryURL)
                        return try store.restore() == directoryURL
                    } catch {
                        return false
                    }
                }
            }

            var succeeded = true
            for await operationSucceeded in group {
                succeeded = succeeded && operationSucceeded
            }
            return succeeded
        }

        #expect(allOperationsSucceeded)
    }

    @Test("成功开始访问的 lease 释放时只停止一次")
    func leaseStopsExactlyOnceAfterSuccessfulStart() {
        let directoryURL = URL(fileURLWithPath: "/tmp/security-scope-success")
        let accessor = FakeSecurityScopedResourceAccessor(startResult: true)
        var lease: SecurityScopedAccessLease? = SecurityScopedAccessLease(
            url: directoryURL,
            accessor: accessor
        )

        #expect(lease?.url == directoryURL)
        #expect(lease?.didStart == true)
        #expect(accessor.startURLs == [directoryURL])
        #expect(accessor.stopURLs.isEmpty)

        lease = nil

        #expect(accessor.startURLs == [directoryURL])
        #expect(accessor.stopURLs == [directoryURL])
    }

    @Test("开始访问失败仍保留 URL，释放时不停止访问")
    func failedStartStillProvidesURLAndDoesNotStop() {
        let directoryURL = URL(fileURLWithPath: "/tmp/security-scope-nonsandboxed")
        let accessor = FakeSecurityScopedResourceAccessor(startResult: false)
        var lease: SecurityScopedAccessLease? = SecurityScopedAccessLease(
            url: directoryURL,
            accessor: accessor
        )

        #expect(lease?.url == directoryURL)
        #expect(lease?.didStart == false)
        #expect(accessor.startURLs == [directoryURL])

        lease = nil

        #expect(accessor.stopURLs.isEmpty)
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "SecurityScopedDirectoryStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}

private enum FakeBookmarkError: Error {
    case corrupt
    case missingResult
}

private final class FakeBookmarkResolver: DirectoryBookmarkResolving, @unchecked Sendable {
    private let lock = NSLock()
    private var storedBookmarkDataResults: [Result<Data, Error>]
    private var storedResolveResults: [Result<(url: URL, isStale: Bool), Error>]
    private var storedBookmarkURLs: [URL] = []
    private var storedResolvedData: [Data] = []

    init(
        bookmarkDataResults: [Result<Data, Error>] = [],
        resolveResults: [Result<(url: URL, isStale: Bool), Error>] = []
    ) {
        self.storedBookmarkDataResults = bookmarkDataResults
        self.storedResolveResults = resolveResults
    }

    var bookmarkURLs: [URL] {
        lock.withLock { storedBookmarkURLs }
    }

    var resolvedData: [Data] {
        lock.withLock { storedResolvedData }
    }

    func bookmarkData(for url: URL) throws -> Data {
        try lock.withLock {
            storedBookmarkURLs.append(url)
            guard !storedBookmarkDataResults.isEmpty else {
                throw FakeBookmarkError.missingResult
            }
            return try storedBookmarkDataResults.removeFirst().get()
        }
    }

    func resolve(_ data: Data) throws -> (url: URL, isStale: Bool) {
        try lock.withLock {
            storedResolvedData.append(data)
            guard !storedResolveResults.isEmpty else {
                throw FakeBookmarkError.missingResult
            }
            return try storedResolveResults.removeFirst().get()
        }
    }
}

private struct IdentityBookmarkResolver: DirectoryBookmarkResolving {
    func bookmarkData(for url: URL) throws -> Data {
        Data(url.path.utf8)
    }

    func resolve(_ data: Data) throws -> (url: URL, isStale: Bool) {
        guard let path = String(data: data, encoding: .utf8) else {
            throw FakeBookmarkError.corrupt
        }
        return (URL(fileURLWithPath: path), false)
    }
}

private final class FakeSecurityScopedResourceAccessor: SecurityScopedResourceAccessing, @unchecked Sendable {
    private let lock = NSLock()
    private let startResult: Bool
    private var storedStartURLs: [URL] = []
    private var storedStopURLs: [URL] = []

    init(startResult: Bool) {
        self.startResult = startResult
    }

    var startURLs: [URL] {
        lock.withLock { storedStartURLs }
    }

    var stopURLs: [URL] {
        lock.withLock { storedStopURLs }
    }

    func start(_ url: URL) -> Bool {
        lock.withLock {
            storedStartURLs.append(url)
            return startResult
        }
    }

    func stop(_ url: URL) {
        lock.withLock {
            storedStopURLs.append(url)
        }
    }
}
