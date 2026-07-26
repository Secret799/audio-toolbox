import Foundation
import Testing
@testable import AudioToolboxCore

@Suite("FileMoverTests")
struct FileMoverTests {
    @Test("文件移动到目标目录并从原位置消失")
    func movesFileIntoDestinationDirectory() async throws {
        let fixture = try TemporaryMoveFixture()
        defer { fixture.remove() }
        let source = try fixture.makeSource(named: "track.mp3", contents: "source")

        let outcome = try await FoundationFileMover().move(
            source,
            to: fixture.destinationDirectory
        )
        let destination = fixture.destinationDirectory.appendingPathComponent(
            source.lastPathComponent
        )

        #expect(outcome == .moved(destination))
        #expect(!FileManager.default.fileExists(atPath: source.path))
        #expect(try Data(contentsOf: destination) == Data("source".utf8))
    }

    @Test("目标目录存在同名文件时拒绝覆盖并保留两端内容")
    func rejectsExistingDestinationWithoutOverwriting() async throws {
        let fixture = try TemporaryMoveFixture()
        defer { fixture.remove() }
        let source = try fixture.makeSource(named: "track.mp3", contents: "source")
        let destination = fixture.destinationDirectory.appendingPathComponent(
            source.lastPathComponent
        )
        try Data("existing".utf8).write(to: destination)

        do {
            _ = try await FoundationFileMover().move(
                source,
                to: fixture.destinationDirectory
            )
            Issue.record("Expected destination conflict")
        } catch let error as FileMoveError {
            #expect(error == .destinationExists(destination))
        }

        #expect(try Data(contentsOf: source) == Data("source".utf8))
        #expect(try Data(contentsOf: destination) == Data("existing".utf8))
    }

    @Test("文件已在目标目录时返回原地结果")
    func returnsAlreadyAtDestinationForSamePath() async throws {
        let fixture = try TemporaryMoveFixture()
        defer { fixture.remove() }
        let source = fixture.destinationDirectory.appendingPathComponent("track.mp3")
        try Data("source".utf8).write(to: source)

        let outcome = try await FoundationFileMover().move(
            source,
            to: fixture.destinationDirectory
        )

        #expect(outcome == .alreadyAtDestination(source))
        #expect(try Data(contentsOf: source) == Data("source".utf8))
    }

    @Test("无效目标目录会报错并保留源文件")
    func invalidDestinationLeavesSourceUntouched() async throws {
        let fixture = try TemporaryMoveFixture()
        defer { fixture.remove() }
        let source = try fixture.makeSource(named: "track.mp3", contents: "source")
        let missingDirectory = fixture.root.appendingPathComponent("missing")

        do {
            _ = try await FoundationFileMover().move(source, to: missingDirectory)
            Issue.record("Expected unavailable destination")
        } catch let error as FileMoveError {
            #expect(error == .destinationUnavailable(missingDirectory))
        }

        #expect(try Data(contentsOf: source) == Data("source".utf8))
    }
}

private struct TemporaryMoveFixture {
    let root: URL
    let sourceDirectory: URL
    let destinationDirectory: URL

    init() throws {
        let fileManager = FileManager.default
        root = fileManager.temporaryDirectory
            .appendingPathComponent("audio-toolbox-file-mover-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        sourceDirectory = root.appendingPathComponent("source", isDirectory: true)
        destinationDirectory = root.appendingPathComponent("destination", isDirectory: true)
        try fileManager.createDirectory(
            at: sourceDirectory,
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: destinationDirectory,
            withIntermediateDirectories: true
        )
    }

    func makeSource(named name: String, contents: String) throws -> URL {
        let url = sourceDirectory.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
