import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: MeetingViewModel
    @State private var isControlSidebarVisible = true

    var body: some View {
        HStack(spacing: 0) {
            if isControlSidebarVisible {
                ControlSidebar {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        isControlSidebarVisible = false
                    }
                }
                .frame(minWidth: 320, idealWidth: 340, maxWidth: 380)
            } else {
                CollapsedSidebarRail {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        isControlSidebarVisible = true
                    }
                }
                .frame(width: 48)
            }
            Divider()
            HStack(spacing: 0) {
                TranscriptView(store: model.transcriptStore)
                    .frame(minWidth: 340, idealWidth: 420)
                Divider()
                AnswerTurnsView(store: model.answerStore)
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(minWidth: isControlSidebarVisible ? 1120 : 840, minHeight: 720)
    }
}

private struct ControlSidebar: View {
    @EnvironmentObject private var model: MeetingViewModel
    let onCollapse: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .center, spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(AppVersion.name)
                                .font(.title2.weight(.semibold))
                            Text("v\(AppVersion.number)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(action: onCollapse) {
                            Image(systemName: "sidebar.left")
                                .frame(width: 24, height: 24)
                        }
                        .buttonStyle(.borderless)
                        .help("Hide configuration sidebar")
                    }
                    StatusBadge(text: model.statusText, running: model.isRunning)
                    if let error = model.lastError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .lineLimit(4)
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    Picker("ASR", selection: $model.config.asrBackend) {
                        ForEach(ASRBackend.allCases) { backend in
                            Text(backend.title).tag(backend)
                        }
                    }
                    .pickerStyle(.segmented)

                    Picker("Audio", selection: $model.config.audioSource) {
                        ForEach(AudioSource.allCases) { source in
                            Text(source.title).tag(source)
                        }
                    }
                    .pickerStyle(.segmented)

                    Picker("Mic Input", selection: $model.config.lockMicrophoneInputDevice) {
                        Text("Follow Default").tag(false)
                        Text("Lock Current").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .disabled(!model.hasMicrophoneInput)
                    .help("Lock the current default microphone input when capture starts")

                    Button {
                        model.toggleMicrophoneMute()
                    } label: {
                        Label(
                            model.isMicrophoneMuted ? "Mic Muted" : "Mute Mic",
                            systemImage: model.isMicrophoneMuted ? "mic.slash.fill" : "mic.fill"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(model.isMicrophoneMuted ? .red : .accentColor)
                    .disabled(!model.hasMicrophoneInput)
                    .help("Temporarily block microphone audio input")

                    MicrophoneLevelPanel(
                        store: model.audioLevelStore,
                        isActive: model.hasMicrophoneInput && model.isRunning && !model.isMicrophoneMuted
                    )

                    Toggle("Mic voice enhance", isOn: microphoneVoiceEnhancementEnabled)
                        .disabled(!model.hasMicrophoneInput)
                        .help("Apply mic-only high-pass, light pre-emphasis, and limiter before ASR")

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Speaker IDs")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        TextField("Mic speaker ID", text: $model.config.microphoneSpeakerName)
                            .textFieldStyle(.roundedBorder)
                        TextField("System audio speaker ID", text: $model.config.systemAudioSpeakerName)
                            .textFieldStyle(.roundedBorder)
                    }

                    if model.config.asrBackend == .aliyunCloud {
                        HStack(spacing: 6) {
                            Text("Workspace")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("llm-")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                            TextField("workspace id", text: aliyunWorkspaceSuffix)
                                .textFieldStyle(.roundedBorder)
                        }
                        TextField("ASR Model ID (default \(AppConfig.defaultAliyunASRModel))", text: $model.config.aliyunASRModel)
                            .textFieldStyle(.roundedBorder)
                        SecureField("Aliyun ASR API Key", text: $model.config.aliyunASRAPIKey)
                            .textFieldStyle(.roundedBorder)
                    } else {
                        TextField("ASR WebSocket", text: $model.config.asrWebSocketURL)
                            .textFieldStyle(.roundedBorder)
                    }
                    TextField("ASR Language", text: $model.config.asrLanguage)
                        .textFieldStyle(.roundedBorder)
                    TextField("ASR Hotwords (space separated)", text: asrHotwords)
                        .textFieldStyle(.roundedBorder)
                    TextField("LLM Base URL", text: $model.config.llmBaseURL)
                        .textFieldStyle(.roundedBorder)
                    TextField("Model", text: $model.config.llmModel)
                        .textFieldStyle(.roundedBorder)
                    SecureField("API Key", text: $model.config.llmAPIKey)
                        .textFieldStyle(.roundedBorder)
                }

                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Enable fusion lane", isOn: $model.config.enableFusionLane)
                    Toggle("Autosave transcript", isOn: transcriptAutosaveEnabled)
                        .help("Save final transcript records to Downloads every 2 minutes while running")
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("History \(model.config.maxHistoryCharacters) chars")
                            Spacer()
                            Text("max 10000")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: historyCharacters, in: 100...10_000, step: 100)
                    }
                    Stepper("Answer memory \(model.config.maxAnswerHistory)", value: $model.config.maxAnswerHistory, in: 3...30)
                    if model.config.asrBackend == .localFunASR {
                        Stepper("Debounce \(model.config.triggerDebounceMS) ms", value: $model.config.triggerDebounceMS, in: 200...2000, step: 100)
                    }
                }
                .font(.callout)

                VStack(spacing: 10) {
                    Button {
                        model.isRunning ? model.stop() : model.start()
                    } label: {
                        Label(model.isRunning ? "Stop" : "Start", systemImage: model.isRunning ? "stop.fill" : "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)

                    HStack {
                        Button {
                            model.saveConfig()
                        } label: {
                            Label("Save", systemImage: "tray.and.arrow.down")
                                .frame(maxWidth: .infinity)
                        }
                        Button {
                            model.clearSession()
                        } label: {
                            Label("Clear", systemImage: "trash")
                                .frame(maxWidth: .infinity)
                        }
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("System Prompt")
                        .font(.headline)
                    TextEditor(text: $model.config.systemPrompt)
                        .font(.system(.caption, design: .default))
                        .frame(minHeight: 120)
                        .scrollContentBackground(.hidden)
                        .background(Color(nsColor: .textBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Enable API log output", isOn: apiLogOutputEnabled)
                    Picker("Log Level", selection: apiLogOutputLevel) {
                        ForEach(APILogOutputLevel.allCases) { level in
                            Text(level.title).tag(level)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(!model.config.enableAPILogOutput)
                }
                .font(.callout)

                APILogPanel(logStore: model.logStore)
            }
            .padding(16)
        }
    }

    private var historyCharacters: Binding<Double> {
        Binding(
            get: { Double(model.config.maxHistoryCharacters) },
            set: { model.config.maxHistoryCharacters = Int($0.rounded()) }
        )
    }

    private var transcriptAutosaveEnabled: Binding<Bool> {
        Binding(
            get: { model.config.enableTranscriptAutosave },
            set: { model.setTranscriptAutosaveEnabled($0) }
        )
    }

    private var aliyunWorkspaceSuffix: Binding<String> {
        Binding(
            get: {
                let cleaned = model.config.aliyunWorkspaceID.trimmingCharacters(in: .whitespacesAndNewlines)
                guard cleaned.hasPrefix("llm-") else { return cleaned }
                return String(cleaned.dropFirst(4))
            },
            set: { value in
                let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if cleaned.isEmpty {
                    model.config.aliyunWorkspaceID = ""
                } else if cleaned.hasPrefix("llm-") {
                    model.config.aliyunWorkspaceID = cleaned
                } else {
                    model.config.aliyunWorkspaceID = "llm-\(cleaned)"
                }
            }
        )
    }

    private var asrHotwords: Binding<String> {
        Binding(
            get: { model.config.asrHotwords },
            set: { model.config.asrHotwords = ASRHotwordFormatter.normalizedInput($0) }
        )
    }

    private var microphoneVoiceEnhancementEnabled: Binding<Bool> {
        Binding(
            get: { model.config.enableMicrophoneVoiceEnhancement },
            set: { model.setMicrophoneVoiceEnhancementEnabled($0) }
        )
    }

    private var apiLogOutputEnabled: Binding<Bool> {
        Binding(
            get: { model.config.enableAPILogOutput },
            set: { model.setAPILogOutputEnabled($0) }
        )
    }

    private var apiLogOutputLevel: Binding<APILogOutputLevel> {
        Binding(
            get: { model.config.apiLogOutputLevel },
            set: { model.setAPILogOutputLevel($0) }
        )
    }
}

private struct MicrophoneLevelPanel: View {
    @ObservedObject var store: AudioLevelStore
    let isActive: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                Label("Mic Level", systemImage: isActive ? "waveform" : "mic.slash")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isActive ? .primary : .secondary)
                Spacer()
                Text(store.microphone.peakText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(levelColor(for: store.microphone.peakDB))
            }

            OBSLevelMeter(snapshot: store.microphone, isActive: isActive)
                .frame(height: 14)

            HStack {
                Text("-60")
                Spacer()
                Text("-20")
                Spacer()
                Text("-9")
                Spacer()
                Text("0")
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .padding(8)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func levelColor(for db: Double) -> Color {
        if db >= -9 {
            return .red
        }
        if db >= -20 {
            return .yellow
        }
        return isActive ? .green : .secondary
    }
}

private struct OBSLevelMeter: View {
    let snapshot: AudioLevelSnapshot
    let isActive: Bool

    var body: some View {
        GeometryReader { proxy in
            let width = max(1, proxy.size.width)
            let rmsWidth = width * snapshot.rmsLevel
            let peakX = min(width - 2, max(0, width * snapshot.peakLevel - 1))

            ZStack(alignment: .leading) {
                MeterSegments()
                    .opacity(0.22)

                MeterSegments()
                    .frame(width: rmsWidth)
                    .clipped()
                    .opacity(isActive ? 1 : 0.35)

                Rectangle()
                    .fill(Color(nsColor: .textBackgroundColor))
                    .frame(width: 2)
                    .offset(x: peakX)
                    .opacity(isActive ? 0.95 : 0.35)
            }
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .overlay {
                RoundedRectangle(cornerRadius: 3)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
            }
        }
    }
}

private struct MeterSegments: View {
    private let greenEnd = AudioLevelSnapshot.normalizedLevel(from: -20)
    private let yellowEnd = AudioLevelSnapshot.normalizedLevel(from: -9)

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            HStack(spacing: 1) {
                Color.green
                    .frame(width: max(0, width * greenEnd))
                Color.yellow
                    .frame(width: max(0, width * (yellowEnd - greenEnd)))
                Color.red
                    .frame(width: max(0, width * (1 - yellowEnd)))
            }
        }
    }
}

private struct APILogPanel: View {
    @EnvironmentObject private var model: MeetingViewModel
    @ObservedObject var logStore: APILogStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("API Log")
                    .font(.headline)
                Spacer()
                Text("\(logStore.entries.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    model.copyAPILogsToClipboard()
                } label: {
                    Image(systemName: "doc.on.doc")
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.borderless)
                .help("Copy all API logs")
                Button {
                    model.exportAPILogsToDownloads()
                } label: {
                    Image(systemName: "square.and.arrow.down")
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.borderless)
                .help("Export API logs to Downloads")
                Button {
                    model.clearLogs()
                } label: {
                    Image(systemName: "trash")
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.borderless)
                .help("Clear API logs")
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(logStore.entries) { entry in
                        APILogRow(entry: entry)
                    }
                }
                .padding(8)
            }
            .frame(minHeight: 180, idealHeight: 220)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
}

private struct APILogRow: View {
    let entry: APILogEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(entry.createdAt.formatted(date: .omitted, time: .standard))
                    .foregroundStyle(.secondary)
                Text(entry.level.rawValue)
                    .foregroundStyle(levelColor)
                Text(entry.source)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .font(.caption2.monospaced())

            Text(entry.message)
                .font(.caption.monospaced())
                .lineLimit(8)
        }
        .padding(.bottom, 4)
    }

    private var levelColor: Color {
        switch entry.level {
        case .info: .secondary
        case .send: .blue
        case .receive: .green
        case .warning: .orange
        case .error: .red
        }
    }
}

private struct CollapsedSidebarRail: View {
    @EnvironmentObject private var model: MeetingViewModel
    let onExpand: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Button(action: onExpand) {
                Image(systemName: "sidebar.right")
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.borderless)
            .help("Show configuration sidebar")

            Circle()
                .fill(model.isRunning ? Color.green : Color.secondary)
                .frame(width: 8, height: 8)

            Spacer(minLength: 0)
        }
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

private struct StatusBadge: View {
    let text: String
    let running: Bool

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(running ? Color.green : Color.secondary)
                .frame(width: 8, height: 8)
            Text(text)
                .font(.caption.weight(.medium))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct TranscriptView: View {
    @EnvironmentObject private var model: MeetingViewModel
    @ObservedObject var store: TranscriptStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TranscriptHeader(store: store)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(livePartials) { segment in
                        TranscriptRow(text: segment.text, time: segment.createdAt, partial: true)
                    }
                    ForEach(store.transcript) { segment in
                        TranscriptRow(text: segment.text, time: segment.createdAt, partial: false)
                    }
                }
                .padding(14)
            }
        }
    }

    private var livePartials: [TranscriptSegment] {
        store.livePartials.values.sorted { left, right in
            left.createdAt > right.createdAt
        }
    }
}

private struct TranscriptHeader: View {
    @EnvironmentObject private var model: MeetingViewModel
    @ObservedObject var store: TranscriptStore

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Live Transcript")
                    .font(.title3.weight(.semibold))
                Text("\(store.transcript.count) segments")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                model.exportTranscriptToDownloads()
            } label: {
                Image(systemName: "square.and.arrow.down")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.borderless)
            .disabled(store.transcript.isEmpty)
            .help("Export final transcript records to Downloads")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

private struct TranscriptRow: View {
    let text: String
    let time: Date
    let partial: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(partial ? "partial" : "final")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(partial ? .orange : .secondary)
                Spacer()
                Text(time.formatted(date: .omitted, time: .standard))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if !partial {
                    Button {
                        copyText()
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .frame(width: 18, height: 18)
                    }
                    .buttonStyle(.borderless)
                    .help("Copy this final transcript segment")
                }
            }
            Text(text)
                .font(.body)
                .foregroundStyle(partial ? .secondary : .primary)
        }
        .padding(10)
        .background(Color(nsColor: partial ? .controlBackgroundColor : .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func copyText() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

private struct AnswerTurnsView: View {
    @ObservedObject var store: AnswerStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Header(title: "Live Answers", subtitle: "\(store.answerTurns.count) turns")
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(store.answerTurns) { turn in
                        AnswerTurnCard(turn: turn)
                    }
                }
                .padding(14)
            }
        }
    }
}

private struct AnswerTurnCard: View {
    let turn: AnswerTurn

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(turn.segment.text)
                    .font(.headline)
                    .lineLimit(3)
                if !turn.finalText.isEmpty {
                    Text(turn.finalText)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.red)
                }
            }

            HStack(alignment: .top, spacing: 10) {
                CandidateCard(
                    candidate: turn.candidates[.current] ?? CandidateAnswer(lane: .current),
                    title: displayTitle(for: .current)
                )
                .frame(maxWidth: .infinity)

                CandidateCard(
                    candidate: turn.candidates[.history500] ?? CandidateAnswer(lane: .history500),
                    title: displayTitle(for: .history500)
                )
                .frame(maxWidth: .infinity)
            }

            CandidateCard(
                candidate: turn.candidates[.answerMemory] ?? CandidateAnswer(lane: .answerMemory),
                title: displayTitle(for: .answerMemory),
                textLineLimit: 8,
                minTextHeight: 82
            )
            .frame(maxWidth: .infinity)
        }
        .padding(12)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func displayTitle(for lane: AnswerLane) -> String {
        switch lane {
        case .current:
            return "Current Segment"
        case .history500:
            return "\(turn.historyCharacterLimit) chars history"
        case .answerMemory:
            return "\(turn.answerHistoryLimit) answer turns"
        case .fusion:
            return "Decision Output"
        }
    }
}

private struct CandidateCard: View {
    let candidate: CandidateAnswer
    let title: String
    var textLineLimit: Int = 6
    var minTextHeight: CGFloat = 58

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                    Text(candidate.lane.subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(statusText)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(statusColor)
            }

            Text(candidate.text.isEmpty ? " " : candidate.text)
                .font(.callout)
                .lineLimit(textLineLimit)
                .frame(maxWidth: .infinity, minHeight: minTextHeight, alignment: .topLeading)
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var statusText: String {
        if let latency = candidate.latencyMS {
            return "\(candidate.status.title) \(latency)ms"
        }
        return candidate.status.title
    }

    private var statusColor: Color {
        switch candidate.status {
        case .complete: .green
        case .running: .orange
        case .failed: .red
        case .skipped: .secondary
        case .idle: .secondary
        }
    }
}

private struct Header: View {
    let title: String
    let subtitle: String

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.title3.weight(.semibold))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}
