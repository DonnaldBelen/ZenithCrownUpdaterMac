import Foundation
import Darwin
import XCTest
@testable import ZenithCrownUpdater

final class UpdateManifestTests: XCTestCase {
    private var root: URL!
    private let old = "data/luafiles514/lua files/skillinfoz/skillid.lub"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("ZenithDeletionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try FileManager.default.removeItem(at: root) }
    }

    @discardableResult
    private func write(_ path: String) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("test contents".utf8).write(to: url)
        return url
    }

    private func plan() throws -> UpdateManifest {
        try UpdateManifest.parse("mhdata.grf|mhdata.grf\n# comment\n#delete|\(old)|mhdata.grf\n", root: root)
    }

    func testThreeSkillFilesAndWindowsPaths() throws {
        let names = ["skillid.lub", "skillinfolist.lub", "skilldescript.lub"]
        let paths = names.map { "data/luafiles514/lua files/skillinfoz/" + $0 }
        var manifest = "mhdata.grf | mhdata.grf\nDATA.INI | DATA.INI\n"
        for path in paths {
            try write(path)
            manifest += "#delete|\(path.replacingOccurrences(of: "/", with: "\\"))|mhdata.grf\n"
        }
        let replacement = try write("mhdata.grf")
        let ini = try write("DATA.INI")
        let plan = try UpdateManifest.parse(manifest, root: root)
        XCTAssertEqual(plan.deletes.count, 3)
        var messages = [String]()
        try plan.applyDeletes(root: root, verified: [replacement.path, ini.path]) { messages.append($0) }
        XCTAssertEqual(messages.filter { $0.hasPrefix("Deleted:") }.count, 3)
        for path in paths { XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path)) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: replacement.path))
        try plan.applyDeletes(root: root, verified: [replacement.path, ini.path]) { messages.append($0) }
        XCTAssertEqual(messages.filter { $0.hasPrefix("Already absent:") }.count, 3)
    }

    func testUnverifiedOrMissingReplacementBlocksDeletion() throws {
        let target = try write(old)
        let plan = try plan()
        XCTAssertThrowsError(try plan.applyDeletes(root: root, verified: []) { _ in })
        XCTAssertThrowsError(try plan.applyDeletes(root: root, verified: [root.appendingPathComponent("mhdata.grf").path]) { _ in })
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
    }

    func testUnrelatedUnverifiedDownloadBlocksDeletion() throws {
        let target = try write(old)
        let replacement = try write("mhdata.grf")
        var plan = try plan()
        plan.files.append(UpdateFile(localPath: "other.dat", remoteName: "other.dat"))
        XCTAssertThrowsError(try plan.applyDeletes(root: root, verified: [replacement.path]) { _ in })
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
    }

    func testReadOnlyAndFinderLockedFile() throws {
        let target = try write(old)
        let replacement = try write("mhdata.grf")
        try FileManager.default.setAttributes([.posixPermissions: 0o444, .immutable: true], ofItemAtPath: target.path)
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: target.path) }
        try plan().applyDeletes(root: root, verified: [replacement.path]) { _ in }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }

    func testMissingParentIsSuccessfulNoOp() throws {
        let replacement = try write("mhdata.grf")
        var messages = [String]()
        try plan().applyDeletes(root: root, verified: [replacement.path]) { messages.append($0) }
        XCTAssertTrue(messages.contains("Already absent: \(root.appendingPathComponent(old).path)"))
    }

    func testPermissionFailureIncludesPathAndRetrySucceeds() throws {
        guard geteuid() != 0 else { throw XCTSkip("Root bypasses POSIX directory permissions") }
        let target = try write(old)
        let replacement = try write("mhdata.grf")
        let parent = target.deletingLastPathComponent()
        let plan = try plan()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: parent.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: parent.path) }
        XCTAssertThrowsError(try plan.applyDeletes(root: root, verified: [replacement.path]) { _ in }) { error in
            XCTAssertTrue(error.localizedDescription.contains(target.path))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: parent.path)
        try plan.applyDeletes(root: root, verified: [replacement.path]) { _ in }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }

    func testUnsafePathsAndDirectories() throws {
        for path in ["", "../outside", "/absolute", "C:\\outside", "a/../b", "a//b", "a/", "a/*", "a/?.lub", "a/x:stream", "a/x."] {
            XCTAssertThrowsError(try UpdateManifest.destination(root: root, relativePath: path), path)
        }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("folder"), withIntermediateDirectories: true)
        XCTAssertThrowsError(try UpdateManifest.destination(root: root, relativePath: "folder"))
    }

    func testSymlinkTargetsAndAncestorsAreRejected() throws {
        let real = try write("real/file.lub")
        let link = root.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real.deletingLastPathComponent())
        XCTAssertThrowsError(try UpdateManifest.destination(root: root, relativePath: "linked/file.lub"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("dangling"), withDestinationURL: root.appendingPathComponent("missing"))
        XCTAssertThrowsError(try UpdateManifest.destination(root: root, relativePath: "dangling"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: real.path))
    }

    func testMalformedConflictingAndDuplicateEntries() throws {
        for text in [
            "#delete|old.lub",
            "\\#delete|old.lub|mhdata.grf",
            "#delete|old.lub|missing.grf",
            "mhdata.grf|mhdata.grf\n#delete|mhdata.grf|mhdata.grf",
            "mhdata.grf|mhdata.grf\nMHDATA.GRF|other.grf",
            "mhdata.grf|mhdata.grf\n#delete|old|mhdata.grf\n#delete|OLD|mhdata.grf",
            "x|remote|extra"
        ] {
            XCTAssertThrowsError(try UpdateManifest.parse(text, root: root), text)
        }
    }
}
