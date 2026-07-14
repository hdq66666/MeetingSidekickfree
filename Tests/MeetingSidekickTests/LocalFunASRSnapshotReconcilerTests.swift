import XCTest
@testable import MeetingSidekickfree

final class LocalFunASRSnapshotReconcilerTests: XCTestCase {
    private let repeatedSnapshot = #"{"sentences":[{"text":"one","start":40,"end":3500},{"text":"two","start":19090,"end":20020},{"text":"three","start":49040,"end":51290}],"partial":"","duration_ms":80920,"is_final":false}"#

    func testRepeatedCumulativeSnapshotEmitsLockedSentencesOnlyOnce() throws {
        let response = try XCTUnwrap(LocalFunASRResponse.parse(jsonString: repeatedSnapshot))
        var reconciler = LocalFunASRSnapshotReconciler()

        XCTAssertFalse(response.isFinal)
        XCTAssertEqual(reconciler.events(for: response).map(\.text), ["one", "two", "three"])

        for _ in 0..<29 {
            XCTAssertTrue(reconciler.events(for: response).isEmpty)
        }
    }

    func testSnapshotGrowthEmitsOnlyNewLockedSentence() throws {
        let initial = try XCTUnwrap(LocalFunASRResponse.parse(jsonString: repeatedSnapshot))
        let grown = try XCTUnwrap(LocalFunASRResponse.parse(jsonString: #"{"sentences":[{"text":"one","start":40,"end":3500},{"text":"two","start":19090,"end":20020},{"text":"three","start":49040,"end":51290},{"text":"four","start":60000,"end":61000}],"partial":"","is_final":false}"#))
        var reconciler = LocalFunASRSnapshotReconciler()

        _ = reconciler.events(for: initial)

        XCTAssertEqual(reconciler.events(for: grown).map(\.text), ["four"])
    }

    func testPartialBecomesStableOnlyWhenResponseIsFinal() throws {
        let ongoing = try XCTUnwrap(LocalFunASRResponse.parse(jsonString: #"{"sentences":[],"partial":"working","partial_start_ms":1000,"duration_ms":1500,"is_final":false}"#))
        let final = try XCTUnwrap(LocalFunASRResponse.parse(jsonString: #"{"sentences":[],"partial":"working","partial_start_ms":1000,"duration_ms":1800,"is_final":true}"#))
        var reconciler = LocalFunASRSnapshotReconciler()

        XCTAssertEqual(reconciler.events(for: ongoing).first?.stable, false)
        let finalEvent = try XCTUnwrap(reconciler.events(for: final).first)
        XCTAssertTrue(finalEvent.stable)
        XCTAssertEqual(finalEvent.endMS, 1800)
        XCTAssertTrue(reconciler.events(for: final).isEmpty)
    }

    func testRepeatedFinalSnapshotDoesNotReemitLockedSentences() throws {
        let response = try XCTUnwrap(LocalFunASRResponse.parse(jsonString: repeatedSnapshot))
        let final = try XCTUnwrap(LocalFunASRResponse.parse(jsonString: #"{"sentences":[{"text":"one","start":40,"end":3500},{"text":"two","start":19090,"end":20020},{"text":"three","start":49040,"end":51290}],"partial":"","is_final":true}"#))
        var reconciler = LocalFunASRSnapshotReconciler()

        _ = reconciler.events(for: response)

        XCTAssertTrue(reconciler.events(for: final).isEmpty)
        XCTAssertTrue(reconciler.events(for: final).isEmpty)
    }

    func testResetStartsANewConnectionIdentityScope() throws {
        let response = try XCTUnwrap(LocalFunASRResponse.parse(jsonString: repeatedSnapshot))
        var reconciler = LocalFunASRSnapshotReconciler()

        _ = reconciler.events(for: response)
        reconciler.reset()

        XCTAssertEqual(reconciler.events(for: response).count, 3)
    }

    func testSeparateAudioConnectionsHaveIndependentSnapshotState() throws {
        let response = try XCTUnwrap(LocalFunASRResponse.parse(jsonString: repeatedSnapshot))
        var microphoneReconciler = LocalFunASRSnapshotReconciler()
        var systemReconciler = LocalFunASRSnapshotReconciler()

        XCTAssertEqual(microphoneReconciler.events(for: response).count, 3)
        XCTAssertTrue(microphoneReconciler.events(for: response).isEmpty)
        XCTAssertEqual(systemReconciler.events(for: response).count, 3)
    }
}
