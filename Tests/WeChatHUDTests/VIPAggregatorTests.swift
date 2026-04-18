import XCTest
@testable import WeChatHUD

final class VIPAggregatorTests: XCTestCase {
    var store: HUDStore!

    override func setUp() {
        super.setUp()
        let tmp = NSTemporaryDirectory() + "test_vipagg_\(UUID().uuidString).sqlite3"
        store = HUDStore(dbPath: tmp)
        try! store.open()
    }

    override func tearDown() { store.close(); super.tearDown() }

    func testPromptLoads() {
        let loader = PromptLoader()
        XCTAssertNoThrow(try loader.load(version: "vip_aggregator_v1"))
    }

    func testTraceCapture() {
        for i in 0..<5 {
            try! store.insertVIPTrace(
                vipUsername: "boss1", vipName: "王总",
                chatUsername: "group\(i % 2)", chatName: "群\(i % 2)",
                msgUID: "msg\(i)", rawText: "text\(i)", msgTime: 1000 + i * 60
            )
        }
        let unbatched = store.loadUnbatchedVIPTraces(vipUsername: "boss1")
        XCTAssertEqual(unbatched.count, 5)
    }

    func testBatchMarking() {
        try! store.insertVIPTrace(
            vipUsername: "boss1", vipName: "王总",
            chatUsername: "g1", chatName: "群1",
            msgUID: "m1", rawText: "t1", msgTime: 1000
        )
        try! store.insertVIPTrace(
            vipUsername: "boss1", vipName: "王总",
            chatUsername: "g2", chatName: "群2",
            msgUID: "m2", rawText: "t2", msgTime: 1060
        )
        let traces = store.loadUnbatchedVIPTraces(vipUsername: "boss1")
        try! store.markVIPTracesBatched(ids: traces.map(\.id), batchID: "batch_001")
        XCTAssertEqual(store.loadUnbatchedVIPTraces(vipUsername: "boss1").count, 0)
    }

    func testAggregateReturnsNilWithoutTraces() {
        let agg = VIPAggregator(store: store, aiService: AIService())
        let semaphore = DispatchSemaphore(value: 0)
        var result: VIPAggregator.AggregateResult?
        Task {
            result = await agg.aggregate(
                vipUsername: "nobody", vipName: "无", vipRole: .boss,
                userNameVariants: [], recentMoodHistory: "",
                lastInteraction: "", commitmentCount: 0
            )
            semaphore.signal()
        }
        semaphore.wait()
        XCTAssertNil(result) // no traces = nil
    }
}
