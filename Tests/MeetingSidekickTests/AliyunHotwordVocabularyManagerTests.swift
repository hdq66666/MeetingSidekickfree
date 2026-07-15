import XCTest
@testable import MeetingSidekickfree

final class AliyunHotwordVocabularyManagerTests: XCTestCase {
    func testConcurrentStreamsShareVocabularyAndReconnectReusesIt() async throws {
        let backend = VocabularyBackend(createDelayNanoseconds: 50_000_000)
        let manager = makeManager(backend: backend)
        let configuration = makeConfiguration(hotwords: "Codex 阿里云")

        async let microphoneID = manager.vocabularyID(for: configuration)
        async let systemID = manager.vocabularyID(for: configuration)
        let (firstID, secondID) = try await (microphoneID, systemID)
        let reconnectID = try await manager.vocabularyID(for: configuration)

        XCTAssertEqual(firstID, "vocabulary-1")
        XCTAssertEqual(secondID, firstID)
        XCTAssertEqual(reconnectID, firstID)
        let countsBeforeReset = await backend.counts()
        XCTAssertEqual(countsBeforeReset, VocabularyBackend.Counts(create: 1, wait: 1, delete: 0))

        let deletedVocabulary = try await manager.reset()
        let countsAfterReset = await backend.counts()
        XCTAssertTrue(deletedVocabulary)
        XCTAssertEqual(countsAfterReset, VocabularyBackend.Counts(create: 1, wait: 1, delete: 1))
    }

    func testPreparationFailureDeletesAllocationAndCachesFailureForSession() async throws {
        let backend = VocabularyBackend(failWhileWaiting: true)
        let manager = makeManager(backend: backend)
        let configuration = makeConfiguration(hotwords: "quota")

        do {
            _ = try await manager.vocabularyID(for: configuration)
            XCTFail("Expected vocabulary preparation to fail")
        } catch {
            XCTAssertEqual(error as? VocabularyBackend.TestError, .waitFailed)
        }

        do {
            _ = try await manager.vocabularyID(for: configuration)
            XCTFail("Expected the cached preparation failure")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("wait failed"))
        }

        let counts = await backend.counts()
        let deletedVocabulary = try await manager.reset()
        XCTAssertEqual(counts, VocabularyBackend.Counts(create: 1, wait: 1, delete: 1))
        XCTAssertFalse(deletedVocabulary)
    }

    func testFailedDeletionRetainsVocabularyForRetry() async throws {
        let backend = VocabularyBackend(deleteFailures: 1)
        let manager = makeManager(backend: backend)
        let configuration = makeConfiguration(hotwords: "retry")

        _ = try await manager.vocabularyID(for: configuration)

        do {
            _ = try await manager.reset()
            XCTFail("Expected the first deletion to fail")
        } catch {
            XCTAssertEqual(error as? VocabularyBackend.TestError, .deleteFailed)
        }

        let deletedVocabulary = try await manager.reset()
        let counts = await backend.counts()
        XCTAssertTrue(deletedVocabulary)
        XCTAssertEqual(counts, VocabularyBackend.Counts(create: 1, wait: 1, delete: 2))
    }

    func testFormatterNormalizesChineseAndEnglishHotwords() {
        let entries = ASRHotwordFormatter.entries(from: "  Codex,阿里云 / API-测试  ")

        XCTAssertEqual(entries.map(\.text), ["Codex", "阿里云", "API", "测试"])
        XCTAssertEqual(entries.map(\.languageCode), ["en", "zh", "en", "zh"])
        XCTAssertEqual(ASRHotwordFormatter.normalizedInput("  Codex,阿里云 / API-测试  "), "Codex 阿里云 API 测试")
    }

    private func makeManager(backend: VocabularyBackend) -> AliyunHotwordVocabularyManager {
        AliyunHotwordVocabularyManager(
            operations: AliyunHotwordVocabularyOperations(
                create: { configuration in
                    try await backend.create(configuration: configuration)
                },
                waitUntilReady: { configuration, vocabularyID in
                    try await backend.waitUntilReady(
                        configuration: configuration,
                        vocabularyID: vocabularyID
                    )
                },
                delete: { configuration, vocabularyID in
                    try await backend.delete(
                        configuration: configuration,
                        vocabularyID: vocabularyID
                    )
                }
            )
        )
    }

    private func makeConfiguration(hotwords: String) -> AliyunHotwordVocabularyConfiguration {
        AliyunHotwordVocabularyConfiguration(
            settings: ASRConnectionSettings(
                backend: .aliyunCloud,
                localURL: "",
                aliyunEndpoint: "wss://llm-test.cn-beijing.maas.aliyuncs.com/api-ws/v1/inference",
                aliyunAPIKey: "test-key",
                aliyunModel: "fun-asr-realtime",
                language: "zh",
                hotwords: hotwords,
                streamName: "test",
                speakerName: nil
            ),
            entries: ASRHotwordFormatter.entries(from: hotwords)
        )
    }
}

private actor VocabularyBackend {
    enum TestError: Error, Equatable, LocalizedError {
        case waitFailed
        case deleteFailed

        var errorDescription: String? {
            switch self {
            case .waitFailed: "wait failed"
            case .deleteFailed: "delete failed"
            }
        }
    }

    struct Counts: Equatable, Sendable {
        let create: Int
        let wait: Int
        let delete: Int
    }

    private let createDelayNanoseconds: UInt64
    private let failWhileWaiting: Bool
    private var deleteFailuresRemaining: Int
    private var createCount = 0
    private var waitCount = 0
    private var deleteCount = 0

    init(
        createDelayNanoseconds: UInt64 = 0,
        failWhileWaiting: Bool = false,
        deleteFailures: Int = 0
    ) {
        self.createDelayNanoseconds = createDelayNanoseconds
        self.failWhileWaiting = failWhileWaiting
        deleteFailuresRemaining = deleteFailures
    }

    func create(configuration: AliyunHotwordVocabularyConfiguration) async throws -> String {
        createCount += 1
        if createDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: createDelayNanoseconds)
        }
        return "vocabulary-\(createCount)"
    }

    func waitUntilReady(
        configuration: AliyunHotwordVocabularyConfiguration,
        vocabularyID: String
    ) throws {
        waitCount += 1
        if failWhileWaiting {
            throw TestError.waitFailed
        }
    }

    func delete(
        configuration: AliyunHotwordVocabularyConfiguration,
        vocabularyID: String
    ) throws {
        deleteCount += 1
        if deleteFailuresRemaining > 0 {
            deleteFailuresRemaining -= 1
            throw TestError.deleteFailed
        }
    }

    func counts() -> Counts {
        Counts(create: createCount, wait: waitCount, delete: deleteCount)
    }
}
