import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: MeetingViewModel

    var body: some View {
        Form {
            Section("OpenAI / vLLM") {
                TextField("Base URL", text: $model.config.llmBaseURL)
                TextField("Model", text: $model.config.llmModel)
                SecureField("API Key", text: $model.config.llmAPIKey)
                Stepper("Max completion tokens: \(model.config.maxCompletionTokens)", value: $model.config.maxCompletionTokens, in: 32...512, step: 16)
                Stepper("Timeout: \(model.config.requestTimeoutSeconds, specifier: "%.1f")s", value: $model.config.requestTimeoutSeconds, in: 1.0...15.0, step: 0.5)
            }

            Section("ASR") {
                Picker("Backend", selection: $model.config.asrBackend) {
                    ForEach(ASRBackend.allCases) { backend in
                        Text(backend.title).tag(backend)
                    }
                }
                if model.config.asrBackend == .aliyunCloud {
                    HStack {
                        Text("Workspace")
                        Text("llm-")
                            .foregroundStyle(.secondary)
                        TextField("workspace id", text: aliyunWorkspaceSuffix)
                    }
                    TextField("ASR Model ID (default \(AppConfig.defaultAliyunASRModel))", text: $model.config.aliyunASRModel)
                    SecureField("Aliyun API Key", text: $model.config.aliyunASRAPIKey)
                } else {
                    TextField("WebSocket URL", text: $model.config.asrWebSocketURL)
                }
                TextField("Language", text: $model.config.asrLanguage)
                TextField("Hotwords (space separated)", text: asrHotwords)
                Picker("Audio Source", selection: $model.config.audioSource) {
                    ForEach(AudioSource.allCases) { source in
                        Text(source.title).tag(source)
                    }
                }
                Picker("Mic Input", selection: $model.config.lockMicrophoneInputDevice) {
                    Text("Follow Default").tag(false)
                    Text("Lock Current").tag(true)
                }
                Toggle("Mic voice enhance", isOn: microphoneVoiceEnhancementEnabled)
                TextField("Mic Speaker ID", text: $model.config.microphoneSpeakerName)
                TextField("System Audio Speaker ID", text: $model.config.systemAudioSpeakerName)
            }

            Section("Output") {
                Toggle("Autosave transcript", isOn: transcriptAutosaveEnabled)
                Toggle("Enable API log output", isOn: apiLogOutputEnabled)
                Picker("API Log Level", selection: apiLogOutputLevel) {
                    ForEach(APILogOutputLevel.allCases) { level in
                        Text(level.title).tag(level)
                    }
                }
                .disabled(!model.config.enableAPILogOutput)
            }

            Section {
                Button("Save Configuration") {
                    model.saveConfig()
                }
            }
        }
        .formStyle(.grouped)
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
