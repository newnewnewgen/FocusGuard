import XCTest
@testable import FocusGuardCore

/// The pure parts of the daemon's Chrome policy writer (chrome pages spec §3): the ownership
/// record codec, the import plist handed to `defaults import`, the bounded read of the console
/// user's plist, and the spawn backoff.
final class ChromePolicyFilesTests: XCTestCase {
    private var dir: String!

    override func setUpWithError() throws {
        dir = NSTemporaryDirectory() + "focusguard-chrome-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: dir)
    }

    // MARK: Record

    func testRecordRoundTripsPatternsAndUser() throws {
        let record = ChromePolicyRecord(patterns: ["chrome://extensions/*", "https://x.com/(a,b)"],
                                        writtenAt: Date(timeIntervalSince1970: 1_700_000_000),
                                        uid: 501, name: "newgen")
        let data = try XCTUnwrap(record.encode())
        XCTAssertEqual(ChromePolicyRecord.decode(data), record)
    }

    func testRecordWithoutUserDecodes() throws {
        // A record written before the user fields existed: patterns are ours, the domain unknown.
        let data = Data(#"{"patterns":["chrome://settings/*"],"writtenAt":0}"#.utf8)
        let record = try XCTUnwrap(ChromePolicyRecord.decode(data))
        XCTAssertEqual(record.patterns, ["chrome://settings/*"])
        XCTAssertNil(record.uid)
        XCTAssertNil(record.name)
    }

    func testUndecodableRecordIsNil() {
        XCTAssertNil(ChromePolicyRecord.decode(Data("not json".utf8)))
    }

    // MARK: Import plist

    func testImportPlistHoldsExactPatternsAsXML() throws {
        let patterns = [#"https://x.com/(a,b)[c]{d}<e>"f""#, "chrome://extensions/*"]
        let data = try ChromeUserImport.plistData(patterns: patterns)
        XCTAssertTrue(String(decoding: data.prefix(5), as: UTF8.self).hasPrefix("<?xml"))
        var format = PropertyListSerialization.PropertyListFormat.binary
        let plist = try PropertyListSerialization.propertyList(from: data, format: &format) as? [String: Any]
        XCTAssertEqual(format, .xml)
        XCTAssertEqual(plist?.keys.sorted(), ["URLBlocklist"])
        XCTAssertEqual(plist?["URLBlocklist"] as? [String], patterns)
    }

    func testBlocklistPresentReadsAnyPlistFormat() throws {
        let xml = try ChromeUserImport.plistData(patterns: ["a"])
        XCTAssertEqual(ChromeUserImport.blocklistPresent(in: xml), true)
        let binary = try PropertyListSerialization.data(fromPropertyList: ["Other": 1], format: .binary, options: 0)
        XCTAssertEqual(ChromeUserImport.blocklistPresent(in: binary), false)
        XCTAssertNil(ChromeUserImport.blocklistPresent(in: Data("garbage".utf8)))
    }

    // MARK: Bounded read

    private func write(_ name: String, _ bytes: Data) -> String {
        let path = dir + "/" + name
        FileManager.default.createFile(atPath: path, contents: bytes)
        return path
    }

    func testRegularFileOwnedByUidIsRead() throws {
        let path = write("regular", Data("hello".utf8))
        let file = try XCTUnwrap(BoundedUserFile.read(path: path, uid: getuid(), limit: 1 << 20).file)
        XCTAssertEqual(file.data, Data("hello".utf8))
        XCTAssertEqual(file.stamp.size, 5)
        XCTAssertEqual(BoundedUserFile.boundedUserFileRead(path: path, uid: getuid(), limit: 1 << 20), Data("hello".utf8))
    }

    func testStampChangesWhenTheFileIsReplaced() throws {
        let path = write("stamped", Data("one".utf8))
        let first = try XCTUnwrap(BoundedUserFile.read(path: path, uid: getuid(), limit: 1 << 20).file)
        // A rename-in-place (how cfprefsd writes) gives a new inode even at the same size.
        let tmp = write("stamped.tmp", Data("two".utf8))
        XCTAssertEqual(rename(tmp, path), 0)
        let second = try XCTUnwrap(BoundedUserFile.read(path: path, uid: getuid(), limit: 1 << 20).file)
        XCTAssertNotEqual(first.stamp, second.stamp)
    }

    func testMissingFileIsAbsent() {
        guard case .absent = BoundedUserFile.read(path: dir + "/nope", uid: getuid(), limit: 1 << 20) else {
            return XCTFail("expected .absent")
        }
        XCTAssertNil(BoundedUserFile.boundedUserFileRead(path: dir + "/nope", uid: getuid(), limit: 1 << 20))
    }

    func testFIFOIsRefusedWithoutBlocking() {
        let path = dir + "/fifo"
        XCTAssertEqual(mkfifo(path, 0o600), 0)
        let started = Date()
        let outcome = BoundedUserFile.read(path: path, uid: getuid(), limit: 1 << 20)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        guard case .refused(let why) = outcome else { return XCTFail("expected .refused, got \(outcome)") }
        XCTAssertTrue(why.contains("regular"), why)
    }

    func testSymlinkIsRefused() {
        let target = write("real", Data("x".utf8))
        let link = dir + "/link"
        XCTAssertEqual(symlink(target, link), 0)
        guard case .refused = BoundedUserFile.read(path: link, uid: getuid(), limit: 1 << 20) else {
            return XCTFail("expected .refused")
        }
    }

    func testOversizeIsRefused() {
        let path = write("big", Data(repeating: 0x20, count: 17))
        guard case .refused(let why) = BoundedUserFile.read(path: path, uid: getuid(), limit: 16) else {
            return XCTFail("expected .refused")
        }
        XCTAssertTrue(why.contains("17"), why)
        XCTAssertNotNil(BoundedUserFile.read(path: path, uid: getuid(), limit: 17).file)
    }

    func testWrongOwnerIsRefused() {
        let path = write("mine", Data("x".utf8))
        guard case .refused(let why) = BoundedUserFile.read(path: path, uid: getuid() &+ 1, limit: 1 << 20) else {
            return XCTFail("expected .refused")
        }
        XCTAssertTrue(why.contains("owned"), why)
    }

    // MARK: Backoff

    func testBackoffHoldsTheLastReasonForTheWindow() {
        var backoff = SpawnBackoff(window: 30)
        let t0 = Date(timeIntervalSince1970: 1000)
        XCTAssertNil(backoff.heldReason(now: t0))
        backoff.failed("exited 1: boom", at: t0)
        XCTAssertEqual(backoff.heldReason(now: t0.addingTimeInterval(29)), "exited 1: boom")
        XCTAssertNil(backoff.heldReason(now: t0.addingTimeInterval(30)))
        backoff.failed("again", at: t0.addingTimeInterval(30))
        backoff.succeeded()
        XCTAssertNil(backoff.heldReason(now: t0.addingTimeInterval(31)))
    }
}
