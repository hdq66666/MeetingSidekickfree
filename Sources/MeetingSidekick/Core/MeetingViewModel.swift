import AppKit
import Foundation

@MainActor
final class MeetingViewModel: ObservableObject {
    @Published var config: AppConfig = .load()
    @Published var isRunning = false
    @Published var statusText = "Idle"
    @Published var lastError: String?
    @Published var isMicrophoneMuted = false

    let transcriptStore = TranscriptStore()
    let answerStore = AnswerStore()
    let logStore = APILogStore()
    let audioLevelStore: AudioLevelStore

    private let openAIClient = OpenAIClient()
    private let microphoneMuteGate = MicrophoneMuteGate()
    private let microphoneEnhancementGate = MicrophoneEnhancementGate()
    private let asrClientRouter = ASRClientRouter()
    private let apiLogOutputGate = APILogOutputGate()
    private let microphoneLevelReporter: AudioLevelReporter
    private var asrClients: [ASRStreamRole: ASRWebSocketClient] = [:]
    private var audioCaptures: [AudioCapture] = []
    private var debounceTasks: [String: Task<Void, Never>] = [:]
    private var answerTasks: [UUID: Task<Void, Never>] = [:]
    private var transcriptAutosaveTask: Task<Void, Never>?
    private var audioStartTask: Task<Void, Never>?
    private var audioStartID = UUID()
    private var lastAutosavedTranscriptID: UUID?
    private var pendingPartialRevisions: [String: Int] = [:]
    private var lastStableFingerprint = ""
    private var seenStableFingerprints = Set<String>()
    private var answerHistory: [String] = []

    init() {
        let audioLevelStore = AudioLevelStore()
        self.audioLevelStore = audioLevelStore
        self.microphoneLevelReporter = AudioLevelReporter(store: audioLevelStore)
        microphoneEnhancementGate.setEnabled(config.enableMicrophoneVoiceEnhancement)
        apiLogOutputGate.update(enabled: config.enableAPILogOutput, level: config.apiLogOutputLevel)
    }

    func saveConfig() {
        config.asrHotwords = ASRHotwordFormatter.normalizedInput(config.asrHotwords)
        microphoneEnhancementGate.setEnabled(config.enableMicrophoneVoiceEnhancement)
        updateLogOutputGate()
        updateTranscriptAutosaveTask()
        config.save()
        statusText = "Configuration saved"
    }

    func start() {
        guard !isRunning else { return }
        config.asrHotwords = ASRHotwordFormatter.normalizedInput(config.asrHotwords)
        config.save()
        updateLogOutputGate()
        microphoneMuteGate.setMuted(isMicrophoneMuted)
        microphoneLevelReporter.reset()
        lastError = nil
        statusText = "Connecting"
        isRunning = true
        let startID = UUID()
        audioStartID = startID
        audioStartTask?.cancel()

        do {
            let config = self.config
            let plans = asrStreamPlans(for: config.audioSource)
            var clients: [ASRStreamRole: ASRWebSocketClient] = [:]

            for plan in plans where shouldStartASRStream(plan) {
                let client = try makeASRClient(for: plan)
                clients[plan.role] = client
            }
            asrClients = clients
            asrClientRouter.setClients(clients)

            let streamSummary = plans
                .map { "\($0.streamName):\($0.speakerName ?? "no-speaker-id")" }
                .joined(separator: ",")
            appendLog(.info, source: "APP", message: "start backend=\(config.asrBackend.title), audio=\(config.audioSource.title), streams=\(streamSummary)")

            let router = asrClientRouter
            let muteGate = microphoneMuteGate
            let enhancementGate = microphoneEnhancementGate
            let microphoneLevelReporter = microphoneLevelReporter
            audioStartTask = Task.detached(priority: .userInitiated) { [weak self, config, router, muteGate, enhancementGate, microphoneLevelReporter, startID] in
                do {
                    let captures = try await Self.makeAudioCaptures(
                        config: config,
                        muteGate: muteGate,
                        enhancementGate: enhancementGate,
                        microphoneLevelReporter: microphoneLevelReporter
                    ) { role, data in
                        router.client(for: role)?.sendPCM(data)
                    }

                    guard !Task.isCancelled else {
                        captures.forEach { $0.stop() }
                        return
                    }

                    await self?.finishAudioStart(captures, startID: startID)
                } catch {
                    await self?.failAudioStart(error, startID: startID)
                }
            }
        } catch {
            stop()
            lastError = error.localizedDescription
            statusText = "Failed"
            appendLog(.error, source: "APP", message: error.localizedDescription)
        }
    }

    func stop() {
        audioStartTask?.cancel()
        audioStartTask = nil
        audioStartID = UUID()
        microphoneLevelReporter.reset()
        for task in debounceTasks.values {
            task.cancel()
        }
        debounceTasks.removeAll()
        pendingPartialRevisions.removeAll()
        for task in answerTasks.values {
            task.cancel()
        }
        answerTasks.removeAll()
        for capture in audioCaptures {
            capture.stop()
        }
        audioCaptures.removeAll()
        for client in asrClients.values {
            client.stopSessionThenClose()
        }
        asrClients.removeAll()
        asrClientRouter.removeAll()
        transcriptAutosaveTask?.cancel()
        transcriptAutosaveTask = nil
        isRunning = false
        statusText = "Stopped"
        appendLog(.info, source: "APP", message: "stopped")
    }

    private func finishAudioStart(_ captures: [AudioCapture], startID: UUID) {
        guard audioStartID == startID, isRunning else {
            captures.forEach { $0.stop() }
            return
        }
        audioCaptures = captures
        statusText = "Running"
        updateTranscriptAutosaveTask()
        appendLog(.info, source: "APP", message: "audio capture started")
        audioStartTask = nil
    }

    private func failAudioStart(_ error: Error, startID: UUID) {
        guard audioStartID == startID else { return }
        stop()
        lastError = error.localizedDescription
        statusText = "Failed"
        appendLog(.error, source: "APP", message: error.localizedDescription)
    }

    /*
     * Audio capture startup can block in CoreAudio while devices are being removed or rebuilt.
     * Keep it out of MainActor so the Stop button remains responsive during hardware changes.
     */
    private static func makeAudioCaptures(
        config: AppConfig,
        muteGate: MicrophoneMuteGate,
        enhancementGate: MicrophoneEnhancementGate,
        microphoneLevelReporter: AudioLevelReporter,
        onFrame: @escaping (ASRStreamRole, Data) -> Void
    ) async throws -> [AudioCapture] {
        let microphoneVoiceEnhancer = MicrophoneVoiceEnhancer()

        switch config.audioSource {
        case .microphone:
            guard await MicrophoneAudioCapture.requestPermission() else {
                throw AudioCaptureError.microphoneDenied
            }
            let capture = MicrophoneAudioCapture(lockInputDevice: config.lockMicrophoneInputDevice)
            capture.onFrame = { data in
                guard !muteGate.isMuted else { return }
                microphoneLevelReporter.ingestPCM16(data)
                let output = enhancementGate.isEnabled ? microphoneVoiceEnhancer.process(data) : data
                onFrame(.single, output)
            }
            try capture.start()
            return [capture]

        case .systemAudio:
            if #available(macOS 13.0, *) {
                let capture = SystemAudioCapture()
                capture.onFrame = { data in onFrame(.single, data) }
                try await capture.start()
                return [capture]
            } else {
                throw AudioCaptureError.unsupportedSystemAudio
            }

        case .microphoneAndSystem:
            if #available(macOS 13.0, *) {
                guard await MicrophoneAudioCapture.requestPermission() else {
                    throw AudioCaptureError.microphoneDenied
                }
                let microphone = MicrophoneAudioCapture(lockInputDevice: config.lockMicrophoneInputDevice)
                let systemAudio = SystemAudioCapture()
                microphone.onFrame = { data in
                    guard !muteGate.isMuted else { return }
                    microphoneLevelReporter.ingestPCM16(data)
                    let output = enhancementGate.isEnabled ? microphoneVoiceEnhancer.process(data) : data
                    onFrame(.microphone, output)
                }
                systemAudio.onFrame = { data in onFrame(.systemAudio, data) }
                do {
                    try microphone.start()
                    try await systemAudio.start()
                    return [microphone, systemAudio]
                } catch {
                    microphone.stop()
                    systemAudio.stop()
                    throw error
                }
            } else {
                throw AudioCaptureError.unsupportedSystemAudio
            }
        }
    }

    func clearSession() {
        transcriptStore.clear()
        answerStore.clear()
        answerHistory.removeAll()
        lastAutosavedTranscriptID = nil
        lastStableFingerprint = ""
        seenStableFingerprints.removeAll()
        lastError = nil
        statusText = isRunning ? "Running" : "Idle"
    }

    func clearLogs() {
        logStore.clear()
    }

    var hasMicrophoneInput: Bool {
        config.audioSource == .microphone || config.audioSource == .microphoneAndSystem
    }

    func toggleMicrophoneMute() {
        setMicrophoneMuted(!isMicrophoneMuted)
    }

    func setMicrophoneMuted(_ muted: Bool) {
        guard isMicrophoneMuted != muted else { return }
        isMicrophoneMuted = muted
        microphoneMuteGate.setMuted(muted)
        if muted {
            microphoneLevelReporter.reset()
            clearMicrophonePartials()
            closeMicrophoneASRStreams()
        } else {
            openMicrophoneASRStreams()
        }
        appendLog(.info, source: "APP", message: muted ? "microphone muted" : "microphone unmuted")
    }

    func setMicrophoneVoiceEnhancementEnabled(_ enabled: Bool) {
        guard config.enableMicrophoneVoiceEnhancement != enabled else { return }
        config.enableMicrophoneVoiceEnhancement = enabled
        microphoneEnhancementGate.setEnabled(enabled)
        appendLog(.info, source: "APP", message: enabled ? "microphone voice enhancement enabled" : "microphone voice enhancement disabled")
    }

    func setTranscriptAutosaveEnabled(_ enabled: Bool) {
        guard config.enableTranscriptAutosave != enabled else { return }
        config.enableTranscriptAutosave = enabled
        updateTranscriptAutosaveTask()
        appendLog(.info, source: "APP", message: enabled ? "transcript autosave enabled" : "transcript autosave disabled")
    }

    func setAPILogOutputEnabled(_ enabled: Bool) {
        guard config.enableAPILogOutput != enabled else { return }
        config.enableAPILogOutput = enabled
        updateLogOutputGate()
        if enabled {
            appendLog(.info, source: "APP", message: "API log output enabled")
        }
    }

    func setAPILogOutputLevel(_ level: APILogOutputLevel) {
        guard config.apiLogOutputLevel != level else { return }
        config.apiLogOutputLevel = level
        updateLogOutputGate()
        appendLog(.info, source: "APP", message: "API log level \(level.title)")
    }

    func copyAPILogsToClipboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(formattedAPILogs(), forType: .string)
        appendLog(.info, source: "APP", message: "copied API logs to clipboard")
    }

    func exportAPILogsToDownloads() {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let fileName = "\(AppVersion.name)-api-log-\(formatter.string(from: Date())).txt"
        let downloadsURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        let outputURL = downloadsURL.appendingPathComponent(fileName)

        do {
            try formattedAPILogs().write(to: outputURL, atomically: true, encoding: .utf8)
            appendLog(.info, source: "APP", message: "exported API logs: \(outputURL.path)")
        } catch {
            lastError = error.localizedDescription
            appendLog(.error, source: "APP", message: "export API logs failed: \(error.localizedDescription)")
        }
    }

    func exportTranscriptToDownloads() {
        do {
            let outputURL = try writeTranscriptToDownloads(autosave: false)
            appendLog(.info, source: "APP", message: "exported transcript: \(outputURL.path)")
        } catch {
            lastError = error.localizedDescription
            appendLog(.error, source: "APP", message: "export transcript failed: \(error.localizedDescription)")
        }
    }

    private func appendLog(_ level: APILogLevel, source: String, message: String) {
        guard apiLogOutputGate.shouldOutput(level) else { return }
        logStore.append(APILogEntry(level: level, source: source, message: message), limit: 300)
    }

    private func formattedAPILogs() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return logStore.entries.reversed().map { entry in
            "[\(formatter.string(from: entry.createdAt))] [\(entry.level.rawValue)] [\(entry.source)] \(entry.message)"
        }.joined(separator: "\n")
    }

    private func formattedTranscriptRecords() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return transcriptStore.transcript.reversed().map { segment in
            [
                "time: \(formatter.string(from: segment.createdAt))",
                "speaker_id: \(normalizedSpeaker(segment.speaker) ?? "none")",
                "content: \(transcriptContent(for: segment))"
            ].joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    private func transcriptContent(for segment: TranscriptSegment) -> String {
        let text = TextUtilities.normalized(segment.text)
        guard let speaker = normalizedSpeaker(segment.speaker) else { return text }
        let prefix = "\(speaker)："
        guard text.hasPrefix(prefix) else { return text }
        return TextUtilities.normalized(String(text.dropFirst(prefix.count)))
    }

    private func updateLogOutputGate() {
        apiLogOutputGate.update(enabled: config.enableAPILogOutput, level: config.apiLogOutputLevel)
    }

    private func updateTranscriptAutosaveTask() {
        transcriptAutosaveTask?.cancel()
        transcriptAutosaveTask = nil
        guard isRunning, config.enableTranscriptAutosave else { return }

        transcriptAutosaveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 120 * 1_000_000_000)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self?.autosaveTranscriptIfNeeded()
                }
            }
        }
    }

    private func autosaveTranscriptIfNeeded() {
        guard let newestSegmentID = transcriptStore.transcript.first?.id,
              newestSegmentID != lastAutosavedTranscriptID else {
            return
        }

        do {
            let outputURL = try writeTranscriptToDownloads(autosave: true)
            lastAutosavedTranscriptID = newestSegmentID
            appendLog(.info, source: "APP", message: "autosaved transcript: \(outputURL.path)")
        } catch {
            lastError = error.localizedDescription
            appendLog(.error, source: "APP", message: "autosave transcript failed: \(error.localizedDescription)")
        }
    }

    @discardableResult
    private func writeTranscriptToDownloads(autosave: Bool) throws -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let marker = autosave ? "-autosave" : ""
        let fileName = "\(AppVersion.name)-transcript\(marker)-\(formatter.string(from: Date())).txt"
        let downloadsURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        let outputURL = downloadsURL.appendingPathComponent(fileName)
        try formattedTranscriptRecords().write(to: outputURL, atomically: true, encoding: .utf8)
        return outputURL
    }

    private func makeASRClient(for plan: ASRStreamPlan) throws -> ASRWebSocketClient {
        let client = ASRWebSocketClient()
        client.onEvent = { [weak self] event in
            Task { @MainActor in
                self?.handleASREvent(event)
            }
        }
        client.onError = { [weak self] error in
            Task { @MainActor in
                self?.lastError = error.localizedDescription
                self?.statusText = "ASR error"
                self?.appendLog(.error, source: "ASR \(plan.streamName)", message: error.localizedDescription)
            }
        }
        client.onLog = { [weak self] level, source, message in
            guard self?.apiLogOutputGate.shouldOutput(level) == true else { return }
            Task { @MainActor in
                self?.appendLog(level, source: source, message: message)
            }
        }
        try client.connect(
            settings: ASRConnectionSettings(
                backend: config.asrBackend,
                localURL: config.asrWebSocketURL,
                aliyunEndpoint: config.aliyunASREndpoint,
                aliyunAPIKey: config.aliyunASRAPIKey,
                aliyunModel: config.effectiveAliyunASRModel,
                language: config.asrLanguage,
                hotwords: config.asrHotwords,
                streamName: plan.streamName,
                speakerName: plan.speakerName
            )
        )
        return client
    }

    private func shouldStartASRStream(_ plan: ASRStreamPlan) -> Bool {
        !(isMicrophoneMuted && isMicrophonePlan(plan))
    }

    private func isMicrophonePlan(_ plan: ASRStreamPlan) -> Bool {
        plan.streamName == "mic"
    }

    private func closeMicrophoneASRStreams() {
        guard isRunning else { return }
        for role in microphoneASRRoles(for: config.audioSource) {
            asrClientRouter.removeClient(for: role)
            asrClients.removeValue(forKey: role)?.stopSessionThenClose(after: 0.2)
        }
        appendLog(.info, source: "APP", message: "microphone ASR websocket closed")
    }

    private func openMicrophoneASRStreams() {
        guard isRunning else { return }
        for plan in asrStreamPlans(for: config.audioSource) where isMicrophonePlan(plan) {
            guard asrClients[plan.role] == nil else { continue }
            do {
                let client = try makeASRClient(for: plan)
                asrClients[plan.role] = client
                asrClientRouter.setClient(client, for: plan.role)
                appendLog(.info, source: "APP", message: "microphone ASR websocket opened")
            } catch {
                lastError = error.localizedDescription
                statusText = "ASR error"
                appendLog(.error, source: "APP", message: "open microphone ASR failed: \(error.localizedDescription)")
            }
        }
    }

    private func microphoneASRRoles(for audioSource: AudioSource) -> [ASRStreamRole] {
        switch audioSource {
        case .microphone:
            return [.single]
        case .microphoneAndSystem:
            return [.microphone]
        case .systemAudio:
            return []
        }
    }

    private func handleASREvent(_ event: ASREvent) {
        guard !isMicrophoneMuted || normalizedStreamName(event.streamName) != "mic" else {
            return
        }

        let key = partialKey(for: event)
        let source = asrLogSource(for: event)
        let speaker = normalizedSpeaker(event.speaker)
        if event.stable {
            transcriptStore.clearPartial(for: key)
            appendLog(.info, source: source, message: "final speaker=\(speaker ?? "none") chars=\(event.text.count) \(event.text)")
            acceptStableSegment(event)
        } else {
            transcriptStore.setPartial(
                TranscriptSegment(
                    text: textWithSpeaker(event.text, speaker: speaker),
                    isFinal: false,
                    speaker: speaker,
                    startMS: event.startMS,
                    endMS: event.endMS
                ),
                for: key
            )
            appendLog(.receive, source: source, message: "partial speaker=\(speaker ?? "none") chars=\(event.text.count) \(event.text)")
            if config.asrBackend == .localFunASR {
                scheduleDebouncedPartial(event)
            }
        }
    }

    private func scheduleDebouncedPartial(_ event: ASREvent) {
        let key = partialKey(for: event)
        let revision = (pendingPartialRevisions[key] ?? 0) + 1
        pendingPartialRevisions[key] = revision
        let delay = UInt64(max(config.triggerDebounceMS, 100)) * 1_000_000
        debounceTasks[key]?.cancel()
        debounceTasks[key] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            await MainActor.run {
                guard let self, revision == self.pendingPartialRevisions[key], !Task.isCancelled else { return }
                self.transcriptStore.clearPartial(for: key)
                self.debounceTasks[key] = nil
                self.acceptStableSegment(event)
            }
        }
    }

    private func acceptStableSegment(_ event: ASREvent) {
        let cleaned = TextUtilities.normalized(event.text)
        guard cleaned.count >= config.minSegmentCharacters else { return }

        let speaker = normalizedSpeaker(event.speaker)
        let streamName = normalizedStreamName(event.streamName)
        let fingerprint = "\(streamName)|\(speaker ?? "")|\(cleaned.lowercased())"
        let eventFingerprint = "\(streamName)|\(speaker ?? "")|\(event.fingerprint)"
        guard fingerprint != lastStableFingerprint || !seenStableFingerprints.contains(eventFingerprint) else { return }
        guard !seenStableFingerprints.contains(eventFingerprint) else { return }
        lastStableFingerprint = fingerprint
        seenStableFingerprints.insert(eventFingerprint)

        let segment = TranscriptSegment(
            text: textWithSpeaker(cleaned, speaker: speaker),
            isFinal: true,
            speaker: speaker,
            startMS: event.startMS,
            endMS: event.endMS
        )
        transcriptStore.prependFinal(segment, limit: 200)
        appendLog(.info, source: "ASR \(streamName)", message: "accepted segment speaker=\(speaker ?? "none") chars=\(cleaned.count)")

        launchAnswerTurn(for: segment)
    }

    private func launchAnswerTurn(for segment: TranscriptSegment) {
        cancelOldAnswerTasks(keepNewest: 4)

        let config = self.config
        let turn = AnswerTurn(
            segment: segment,
            historyCharacterLimit: config.maxHistoryCharacters,
            answerHistoryLimit: config.maxAnswerHistory
        )
        answerStore.prepend(turn, limit: 80)

        for lane in [AnswerLane.current, .history500, .answerMemory] {
            setCandidate(turnID: turn.id, lane: lane, status: .running)
        }
        if config.enableFusionLane {
            setCandidate(turnID: turn.id, lane: .fusion, status: .running)
        } else {
            setCandidate(turnID: turn.id, lane: .fusion, status: .skipped)
        }

        let history500 = makeHistory500(excluding: segment.id, limit: config.maxHistoryCharacters)
        let priorAnswers = Array(answerHistory.suffix(config.maxAnswerHistory))
        let client = openAIClient
        appendLog(.info, source: "LLM", message: "turn settings history=\(config.maxHistoryCharacters), answerMemory=\(config.maxAnswerHistory)")

        let task = Task { [weak self] in
            let lanes: [AnswerLane] = [.current, .history500, .answerMemory]
            var results: [AnswerLane: LLMResult] = [:]

            await withTaskGroup(of: (AnswerLane, Result<LLMResult, Error>).self) { group in
                for lane in lanes {
                    let prompt = PromptBuilder.prompt(
                        for: lane,
                        currentSegment: segment.text,
                        history500: history500,
                        answerHistory: priorAnswers
                    )
                    await MainActor.run {
                        self?.appendLog(.send, source: "LLM", message: "\(lane.title) request chars=\(prompt.count)")
                    }
                    group.addTask {
                        do {
                            let result = try await client.complete(
                                baseURL: config.llmBaseURL,
                                apiKey: config.llmAPIKey,
                                model: config.llmModel,
                                systemPrompt: config.systemPrompt,
                                userPrompt: prompt,
                                maxTokens: config.maxCompletionTokens,
                                timeout: config.requestTimeoutSeconds
                            )
                            return (lane, .success(result))
                        } catch {
                            return (lane, .failure(error))
                        }
                    }
                }

                for await (lane, result) in group {
                    guard !Task.isCancelled else { return }
                    switch result {
                    case let .success(llmResult):
                        results[lane] = llmResult
                        await MainActor.run {
                            self?.appendLog(.receive, source: "LLM", message: "\(lane.title) done \(llmResult.latencyMS)ms chars=\(llmResult.text.count)")
                            self?.setCandidate(
                                turnID: turn.id,
                                lane: lane,
                                text: llmResult.text,
                                latencyMS: llmResult.latencyMS,
                                status: llmResult.text.isEmpty ? .skipped : .complete
                            )
                            self?.setFinalTextIfUseful(turnID: turn.id, candidates: results.mapValues(\.text))
                        }

                    case let .failure(error):
                        await MainActor.run {
                            self?.appendLog(.error, source: "LLM", message: "\(lane.title) failed: \(error.localizedDescription)")
                            self?.setCandidate(turnID: turn.id, lane: lane, status: .failed(error.localizedDescription))
                        }
                    }
                }
            }

            guard !Task.isCancelled else { return }
            let candidateTexts = results.mapValues(\.text)

            if config.enableFusionLane, candidateTexts.values.filter({ !$0.isEmpty }).count > 1 {
                let fusionPrompt = PromptBuilder.prompt(
                    for: .fusion,
                    currentSegment: segment.text,
                    history500: history500,
                    answerHistory: priorAnswers,
                    candidates: candidateTexts
                )
                await MainActor.run {
                    self?.appendLog(.send, source: "LLM", message: "\(AnswerLane.fusion.title) request chars=\(fusionPrompt.count)")
                }
                do {
                    let fusion = try await client.complete(
                        baseURL: config.llmBaseURL,
                        apiKey: config.llmAPIKey,
                        model: config.llmModel,
                        systemPrompt: config.systemPrompt,
                        userPrompt: fusionPrompt,
                        maxTokens: min(config.maxCompletionTokens, 160),
                        timeout: config.requestTimeoutSeconds
                    )
                    await MainActor.run {
                        self?.appendLog(.receive, source: "LLM", message: "\(AnswerLane.fusion.title) done \(fusion.latencyMS)ms chars=\(fusion.text.count)")
                        self?.setCandidate(
                            turnID: turn.id,
                            lane: .fusion,
                            text: fusion.text,
                            latencyMS: fusion.latencyMS,
                            status: fusion.text.isEmpty ? .skipped : .complete
                        )
                        self?.setFinalText(turnID: turn.id, text: fusion.text.isEmpty ? self?.bestLocalAnswer(candidateTexts) ?? "" : fusion.text)
                    }
                } catch {
                    await MainActor.run {
                        self?.appendLog(.error, source: "LLM", message: "\(AnswerLane.fusion.title) failed: \(error.localizedDescription)")
                        self?.setCandidate(turnID: turn.id, lane: .fusion, status: .failed(error.localizedDescription))
                        self?.setFinalText(turnID: turn.id, text: self?.bestLocalAnswer(candidateTexts) ?? "")
                    }
                }
            } else {
                await MainActor.run {
                    self?.setCandidate(turnID: turn.id, lane: .fusion, status: .skipped)
                    self?.setFinalText(turnID: turn.id, text: self?.bestLocalAnswer(candidateTexts) ?? "")
                }
            }

            await MainActor.run {
                self?.answerTasks[turn.id] = nil
            }
        }

        answerTasks[turn.id] = task
    }

    private func cancelOldAnswerTasks(keepNewest: Int) {
        guard answerTasks.count >= keepNewest else { return }
        let keepIDs = Set(answerStore.answerTurns.prefix(max(keepNewest - 1, 0)).map(\.id))
        for id in answerTasks.keys where !keepIDs.contains(id) {
            answerTasks[id]?.cancel()
            answerTasks[id] = nil
        }
    }

    private func makeHistory500(excluding segmentID: UUID, limit: Int) -> String {
        let ordered = transcriptStore.transcript
            .filter { $0.id != segmentID }
            .reversed()
            .map(\.text)
            .joined(separator: "\n")
        return TextUtilities.suffixCharacters(ordered, limit: limit)
    }

    private func setCandidate(
        turnID: UUID,
        lane: AnswerLane,
        text: String? = nil,
        latencyMS: Int? = nil,
        status: CandidateStatus
    ) {
        answerStore.setCandidate(turnID: turnID, lane: lane, text: text, latencyMS: latencyMS, status: status)
    }

    private func setFinalTextIfUseful(turnID: UUID, candidates: [AnswerLane: String]) {
        let best = bestLocalAnswer(candidates)
        guard !best.isEmpty else { return }
        setFinalText(turnID: turnID, text: best, recordHistory: false)
    }

    private func setFinalText(turnID: UUID, text: String, recordHistory: Bool = true) {
        let cleaned = TextUtilities.normalized(text)
        answerStore.setFinalText(turnID: turnID, text: cleaned)
        if recordHistory, !cleaned.isEmpty, answerHistory.last != cleaned {
            answerHistory.append(cleaned)
            if answerHistory.count > max(config.maxAnswerHistory, 20) {
                answerHistory.removeFirst(answerHistory.count - max(config.maxAnswerHistory, 20))
            }
        }
    }

    private func bestLocalAnswer(_ candidates: [AnswerLane: String]) -> String {
        let preferred: [AnswerLane] = [.history500, .current, .answerMemory]
        var seen = Set<String>()

        for lane in preferred {
            guard let cleaned = TextUtilities.nonEmpty(candidates[lane] ?? "") else { continue }
            let key = cleaned.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            return cleaned
        }
        return ""
    }

    private func asrStreamPlans(for audioSource: AudioSource) -> [ASRStreamPlan] {
        switch audioSource {
        case .microphone:
            return [ASRStreamPlan(role: .single, streamName: "mic", speakerName: configuredSpeakerName(config.microphoneSpeakerName))]
        case .systemAudio:
            return [ASRStreamPlan(role: .single, streamName: "system", speakerName: configuredSpeakerName(config.systemAudioSpeakerName))]
        case .microphoneAndSystem:
            return [
                ASRStreamPlan(role: .microphone, streamName: "mic", speakerName: configuredSpeakerName(config.microphoneSpeakerName)),
                ASRStreamPlan(role: .systemAudio, streamName: "system", speakerName: configuredSpeakerName(config.systemAudioSpeakerName))
            ]
        }
    }

    private func configuredSpeakerName(_ value: String) -> String? {
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    private func normalizedSpeaker(_ speaker: String?) -> String? {
        let cleaned = speaker?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return cleaned.isEmpty ? nil : cleaned
    }

    private func normalizedStreamName(_ streamName: String?) -> String {
        let cleaned = streamName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return cleaned.isEmpty ? "unknown" : cleaned
    }

    private func asrLogSource(for event: ASREvent) -> String {
        "ASR \(normalizedStreamName(event.streamName))"
    }

    private func clearMicrophonePartials() {
        transcriptStore.clearPartials { $0.hasPrefix("mic|") }
        for key in Array(debounceTasks.keys) where key.hasPrefix("mic|") {
            debounceTasks[key]?.cancel()
            debounceTasks[key] = nil
            pendingPartialRevisions[key] = nil
        }
    }

    private func textWithSpeaker(_ text: String, speaker: String?) -> String {
        guard let speaker else { return text }
        return "\(speaker)：\(text)"
    }

    private func partialKey(for event: ASREvent) -> String {
        "\(normalizedStreamName(event.streamName))|\(normalizedSpeaker(event.speaker) ?? "none")"
    }
}

private enum ASRStreamRole: Hashable {
    case single
    case microphone
    case systemAudio
}

private struct ASRStreamPlan {
    let role: ASRStreamRole
    let streamName: String
    let speakerName: String?
}

private final class ASRClientRouter: @unchecked Sendable {
    private let lock = NSLock()
    private var clients: [ASRStreamRole: ASRWebSocketClient] = [:]

    func setClients(_ clients: [ASRStreamRole: ASRWebSocketClient]) {
        lock.lock()
        self.clients = clients
        lock.unlock()
    }

    func setClient(_ client: ASRWebSocketClient, for role: ASRStreamRole) {
        lock.lock()
        clients[role] = client
        lock.unlock()
    }

    func removeClient(for role: ASRStreamRole) {
        lock.lock()
        clients[role] = nil
        lock.unlock()
    }

    func removeAll() {
        lock.lock()
        clients.removeAll()
        lock.unlock()
    }

    func client(for role: ASRStreamRole) -> ASRWebSocketClient? {
        lock.lock()
        defer { lock.unlock() }
        return clients[role]
    }
}

private final class MicrophoneMuteGate: @unchecked Sendable {
    private let lock = NSLock()
    private var muted = false

    var isMuted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return muted
    }

    func setMuted(_ muted: Bool) {
        lock.lock()
        self.muted = muted
        lock.unlock()
    }
}

private final class MicrophoneEnhancementGate: @unchecked Sendable {
    private let lock = NSLock()
    private var enabled = true

    var isEnabled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return enabled
    }

    func setEnabled(_ enabled: Bool) {
        lock.lock()
        self.enabled = enabled
        lock.unlock()
    }
}

private final class APILogOutputGate: @unchecked Sendable {
    private let lock = NSLock()
    private var enabled = true
    private var level: APILogOutputLevel = .errorsOnly

    func update(enabled: Bool, level: APILogOutputLevel) {
        lock.lock()
        self.enabled = enabled
        self.level = level
        lock.unlock()
    }

    func shouldOutput(_ logLevel: APILogLevel) -> Bool {
        lock.lock()
        let shouldOutput = enabled && level.includes(logLevel)
        lock.unlock()
        return shouldOutput
    }
}
