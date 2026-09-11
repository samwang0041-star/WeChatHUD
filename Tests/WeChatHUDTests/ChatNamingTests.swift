import XCTest
import SQLite3
@testable import WeChatHUD

/// WeChat leaves a large share of groups unnamed (`43753159251@chatroom` and
/// 356 more on the reference account). These tests pin the rules that keep
/// such an id from ever reaching the UI as if it were a name.
final class ChatNamingTests: XCTestCase {
    private var store: HUDStore!
    private var tmpPath: String!

    override func setUp() {
        tmpPath = NSTemporaryDirectory() + "chat_naming_\(UUID().uuidString).sqlite3"
        store = HUDStore(dbPath: tmpPath)
        try! store.open()
    }

    override func tearDown() {
        store.close()
        try? FileManager.default.removeItem(atPath: tmpPath)
    }

    // MARK: - Raw identifier detection

    func testRawIdentifiersAreRecognised() {
        XCTAssertTrue(ContactIdentityIndex.isRawChatIdentifier("43753159251@chatroom"))
        XCTAssertTrue(ContactIdentityIndex.isRawChatIdentifier("wxid_n0w45t0smsd141"))
        XCTAssertTrue(ContactIdentityIndex.isRawChatIdentifier("25984985478086417@openim"))
        XCTAssertTrue(ContactIdentityIndex.isRawChatIdentifier("  wxid_spaced  "))
    }

    func testRealNamesAreNotTreatedAsIdentifiers() {
        XCTAssertFalse(ContactIdentityIndex.isRawChatIdentifier("产品营销组"))
        XCTAssertFalse(ContactIdentityIndex.isRawChatIdentifier("未命名群聊"))
        XCTAssertFalse(ContactIdentityIndex.isRawChatIdentifier("群聊 · 赖豪、张沛"))
        XCTAssertFalse(ContactIdentityIndex.isRawChatIdentifier(""))
    }

    // MARK: - Member-derived fallback

    func testMemberDerivedLabelListsMembers() {
        let label = ContactIdentityIndex.memberDerivedGroupLabel(memberNames: ["赖豪", "张沛", "索洛诺勋"])
        XCTAssertEqual(label, "群聊 · 赖豪、张沛、索洛诺勋")
    }

    func testMemberDerivedLabelCapsAndDeduplicates() {
        let label = ContactIdentityIndex.memberDerivedGroupLabel(memberNames: ["赖豪", "赖豪", "张沛", "索洛诺勋", "王五"])
        XCTAssertEqual(label, "群聊 · 赖豪、张沛、索洛诺勋 等")
    }

    func testMemberDerivedLabelIgnoresUsernamesWithoutNames() {
        // A wxid is exactly the thing the fallback exists to avoid showing.
        XCTAssertNil(ContactIdentityIndex.memberDerivedGroupLabel(memberNames: ["wxid_abc", "", "  "]))
    }

    func testUnnamedGroupPlaceholderIsUsedInsteadOfRoomId() {
        let index = ContactIdentityIndex.build(records: [
            .init(username: "43753159251@chatroom", nickName: "", remark: "")
        ])
        XCTAssertEqual(index.displayName(for: "43753159251@chatroom"), ContactIdentityIndex.unnamedGroupPlaceholder)
        XCTAssertEqual(ContactIdentityIndex.unnamedGroupPlaceholder, "未命名群聊")
    }

    func testWeChatNamePresenceIsTrackedSeparatelyFromDisplayName() {
        let index = ContactIdentityIndex.build(records: [
            .init(username: "43753159251@chatroom", nickName: "", remark: ""),
            .init(username: "54461316910@chatroom", nickName: "产品营销组", remark: ""),
            .init(username: "wxid_x", nickName: "张沛", remark: "备注优先")
        ])

        // Display falls back to a placeholder, but WeChat genuinely has no name.
        XCTAssertEqual(index.displayName(for: "43753159251@chatroom"), ContactIdentityIndex.unnamedGroupPlaceholder)
        XCTAssertEqual(index.weChatNameByUsername["43753159251@chatroom"], "")
        XCTAssertEqual(index.weChatNameByUsername["54461316910@chatroom"], "产品营销组")
        // Remark wins over nickname for the WeChat-reported name.
        XCTAssertEqual(index.weChatNameByUsername["wxid_x"], "备注优先")
    }

    // MARK: - Alias storage

    func testAliasRoundTripAndClear() throws {
        XCTAssertNil(store.chatAlias(for: "43753159251@chatroom"))
        try store.setChatAlias(username: "43753159251@chatroom", displayName: "供应链周会")
        XCTAssertEqual(store.chatAlias(for: "43753159251@chatroom"), "供应链周会")

        try store.removeChatAlias(username: "43753159251@chatroom")
        XCTAssertNil(store.chatAlias(for: "43753159251@chatroom"))
    }

    func testEmptyAliasClearsExistingName() throws {
        try store.setChatAlias(username: "chat", displayName: "旧名字")
        try store.setChatAlias(username: "chat", displayName: "   ")
        XCTAssertNil(store.chatAlias(for: "chat"))
    }

    func testWeChatSearchPrefersCurrentRemarkOverStaleStoredName() {
        let names = WeChatOpenSearch.names(
            liveRemark: "新备注",
            liveNick: "曾某某",
            hudAlias: nil,
            stored: ["个金小曾"],
            username: "wxid_xiaozeng"
        )
        XCTAssertEqual(names.first, "新备注")
        XCTAssertTrue(names.contains("个金小曾"))
        XCTAssertTrue(names.contains("wxid_xiaozeng"))
        XCTAssertLessThan(names.firstIndex(of: "新备注")!, names.firstIndex(of: "个金小曾")!)
    }

    func testWeChatTitleMatchesAnySearchName() {
        XCTAssertTrue(WeChatOpenSearch.titleMatches("新备注 (2)", acceptable: ["个金小曾", "新备注"]))
        XCTAssertFalse(WeChatOpenSearch.titleMatches("别人", acceptable: ["个金小曾", "新备注"]))
    }

    func testIdentitySearchNamesPutRemarkFirst() {
        let index = ContactIdentityIndex.build(records: [
            .init(username: "wxid_x", nickName: "曾某某", remark: "新备注")
        ])
        XCTAssertEqual(index.searchNames(for: "wxid_x").first, "新备注")
        XCTAssertEqual(index.searchNames(for: "wxid_x"), ["新备注", "曾某某", "wxid_x"])
    }

    // MARK: - Repair of previously persisted rows

    @MainActor
    func testRepairRewritesRawIdsInPersistedRows() throws {
        let raw = "43753159251@chatroom"
        try insertCommitment(msgUID: "uid-1", chatUsername: raw, chatName: raw)
        XCTAssertEqual(store.loadCommitments().first?.chatName, raw)

        let changed = ChatMonitor.repairStaleChatNames(store: store) { _ in "群聊 · 赖豪、张沛" }

        XCTAssertEqual(changed, 1)
        XCTAssertEqual(store.loadCommitments().first?.chatName, "群聊 · 赖豪、张沛")
    }

    @MainActor
    func testRepairLeavesRowsWithRealNamesAlone() throws {
        try insertCommitment(msgUID: "uid-2", chatUsername: "54461316910@chatroom", chatName: "产品营销组")

        let changed = ChatMonitor.repairStaleChatNames(store: store) { _ in "不该用到" }

        XCTAssertEqual(changed, 0)
        XCTAssertEqual(store.loadCommitments().first?.chatName, "产品营销组")
    }

    @MainActor
    func testRepairKeepsRawIdWhenNoBetterNameExists() throws {
        let raw = "43753159251@chatroom"
        try insertCommitment(msgUID: "uid-3", chatUsername: raw, chatName: raw)

        // Resolver has nothing better — never blank the row out.
        let changed = ChatMonitor.repairStaleChatNames(store: store) { _ in nil }

        XCTAssertEqual(changed, 0)
        XCTAssertEqual(store.loadCommitments().first?.chatName, raw)
    }

    /// The commit-target loop had no test at all: only a copy of it lived in
    /// this file. Driving the production static pins the "raw id only, never a
    /// person's name" rule it relies on.
    @MainActor
    func testCommitTargetRepairRewritesRawIdsThroughProductionLoop() throws {
        let raw = "43753159251@chatroom"
        try store.upsertCommitment(
            msgUID: "uid-target-loop", chatUsername: raw, chatName: raw,
            content: "立基本框架", commitTo: raw,
            confidence: 0.9, promptVersion: "v1"
        )

        let changed = ChatMonitor.repairStaleCommitTargets(store: store) { _ in "群聊 · 赖豪、张沛" }

        XCTAssertEqual(changed, 1)
        XCTAssertEqual(store.loadCommitments().first?.commitTo, "群聊 · 赖豪、张沛")
    }

    @MainActor
    func testCommitTargetRepairKeepsUnresolvableTarget() throws {
        let raw = "43753159251@chatroom"
        try store.upsertCommitment(
            msgUID: "uid-target-loop-2", chatUsername: raw, chatName: raw,
            content: "立基本框架", commitTo: raw,
            confidence: 0.9, promptVersion: "v1"
        )

        XCTAssertEqual(ChatMonitor.repairStaleCommitTargets(store: store) { _ in nil }, 0)
        XCTAssertEqual(store.loadCommitments().first?.commitTo, raw)
    }

    func testPropagateChatNameUpdatesExistingRows() throws {
        let raw = "43753159251@chatroom"
        try insertCommitment(msgUID: "uid-4", chatUsername: raw, chatName: ContactIdentityIndex.unnamedGroupPlaceholder)

        let changed = store.propagateChatName(username: raw, displayName: "供应链周会")

        XCTAssertEqual(changed, 1)
        XCTAssertEqual(store.loadCommitments().first?.chatName, "供应链周会")
    }

    func testRenameAlsoRewritesCommitTargetsThatNamedTheChat() throws {
        let raw = "43753159251@chatroom"
        try store.upsertCommitment(
            msgUID: "uid-rename", chatUsername: raw, chatName: ContactIdentityIndex.unnamedGroupPlaceholder,
            content: "发合同", commitTo: ContactIdentityIndex.unnamedGroupPlaceholder,
            confidence: 0.9, promptVersion: "v1"
        )

        try store.setChatAlias(
            username: raw, displayName: "供应链周会",
            previousName: ContactIdentityIndex.unnamedGroupPlaceholder
        )

        let commitment = store.loadCommitments().first
        XCTAssertEqual(commitment?.chatName, "供应链周会")
        XCTAssertEqual(commitment?.commitTo, "供应链周会")
    }

    func testRenameLeavesCommitTargetsNamingAPersonAlone() throws {
        let raw = "43753159251@chatroom"
        try store.upsertCommitment(
            msgUID: "uid-person", chatUsername: raw, chatName: ContactIdentityIndex.unnamedGroupPlaceholder,
            content: "发合同", commitTo: "赖豪",
            confidence: 0.9, promptVersion: "v1"
        )

        try store.setChatAlias(
            username: raw, displayName: "供应链周会",
            previousName: ContactIdentityIndex.unnamedGroupPlaceholder
        )

        XCTAssertEqual(store.loadCommitments().first?.commitTo, "赖豪")
    }

    private func insertCommitment(msgUID: String, chatUsername: String, chatName: String) throws {
        try store.upsertCommitment(
            msgUID: msgUID,
            chatUsername: chatUsername,
            chatName: chatName,
            content: "确认物料",
            commitTo: "赖豪",
            confidence: 0.9,
            promptVersion: "v1"
        )
    }

    // MARK: - Member recovery from contact.db

    func testCommitTargetRepairRewritesRawIds() throws {
        let raw = "43753159251@chatroom"
        try store.upsertCommitment(
            msgUID: "uid-target", chatUsername: raw, chatName: raw,
            content: "立基本框架", commitTo: raw,
            confidence: 0.9, promptVersion: "v1"
        )
        let rows = store.uninformativeCommitTargets()
        XCTAssertEqual(rows.map(\.target), [raw])

        let changed = store.applyResolvedCommitTargets(
            rows.map { (msgUID: $0.msgUID, oldTarget: $0.target, newTarget: "群聊 · 上步雍勋、张沛、赖豪") }
        )

        XCTAssertEqual(changed, 1)
        XCTAssertEqual(store.loadCommitments().first?.commitTo, "群聊 · 上步雍勋、张沛、赖豪")
        XCTAssertTrue(store.uninformativeCommitTargets().isEmpty)
    }

    func testCommitTargetWithHumanNameIsUntouched() throws {
        try store.upsertCommitment(
            msgUID: "uid-target-ok", chatUsername: "43753159251@chatroom", chatName: "群聊 · 赖豪",
            content: "发文件", commitTo: "赖豪",
            confidence: 0.9, promptVersion: "v1"
        )
        XCTAssertTrue(store.uninformativeCommitTargets().isEmpty)
        XCTAssertEqual(store.loadCommitments().first?.commitTo, "赖豪")
    }

    func testGroupMemberNamesRecoveredForNamelessGroup() throws {
        let dir = NSTemporaryDirectory() + "chat_naming_db_\(UUID().uuidString)"
        let contactDir = dir + "/contact"
        try FileManager.default.createDirectory(atPath: contactDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let contactPath = contactDir + "/contact.db"
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(contactPath, &db), SQLITE_OK)
        let schema = """
            CREATE TABLE contact(id INTEGER PRIMARY KEY, username TEXT, nick_name TEXT, remark TEXT);
            CREATE TABLE chat_room(id INTEGER PRIMARY KEY, username TEXT, owner TEXT, ext_buffer BLOB);
            CREATE TABLE chatroom_member(room_id INTEGER, member_id INTEGER);
            CREATE TABLE name2id(username TEXT PRIMARY KEY);
            INSERT INTO contact(username, nick_name, remark) VALUES('43753159251@chatroom', '', '');
            INSERT INTO contact(username, nick_name, remark) VALUES('wxid_laihao', '赖豪', '');
            INSERT INTO contact(username, nick_name, remark) VALUES('wxid_zhangpei', 'mr.zhang', '张沛');
            INSERT INTO chat_room(id, username) VALUES(1, '43753159251@chatroom');
            INSERT INTO name2id(rowid, username) VALUES(1, 'yuriwong');
            INSERT INTO name2id(rowid, username) VALUES(2, 'wxid_laihao');
            INSERT INTO name2id(rowid, username) VALUES(3, 'wxid_zhangpei');
            INSERT INTO chatroom_member(room_id, member_id) VALUES(1, 1);
            INSERT INTO chatroom_member(room_id, member_id) VALUES(1, 2);
            INSERT INTO chatroom_member(room_id, member_id) VALUES(1, 3);
            """
        XCTAssertEqual(sqlite3_exec(db, schema, nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)

        let reader = WeChatReader(keysPath: dir + "/keys.json", dbDir: dir, cacheStrategy: .memory)
        let index = ContactIdentityIndex.build(records: [
            .init(username: "43753159251@chatroom", nickName: "", remark: ""),
            .init(username: "wxid_laihao", nickName: "赖豪", remark: ""),
            .init(username: "wxid_zhangpei", nickName: "mr.zhang", remark: "张培")
        ])
        XCTAssertEqual(index.displayName(for: "43753159251@chatroom"), ContactIdentityIndex.unnamedGroupPlaceholder)

        // Drive the production JOIN — this is the query whose result becomes the
        // group's display name. The previous version ran a copy of the SQL here
        // and threw the reader away, so `loadGroupMemberNames` never executed.
        var contactDB: OpaquePointer?
        XCTAssertEqual(sqlite3_open(contactPath, &contactDB), SQLITE_OK)
        reader.loadGroupMemberNames(db: contactDB, knownNames: index.displayNameByUsername)
        sqlite3_close(contactDB)

        XCTAssertEqual(
            reader.groupMemberNames(for: "43753159251@chatroom"), ["赖豪", "张沛"],
            "the member join is what turns a nameless room into a usable label"
        )
        XCTAssertEqual(reader.displayName(for: "43753159251@chatroom"), "群聊 · 赖豪、张沛")
    }
}
