import SwiftUI

/// Transcription behavior: automatic transcription, language selection, transcript style,
/// speech recognition engine selection (On-Device vs. Soniox Cloud AI), Soniox tuning,
/// and speaker directory management.
/// Transcription behavior: sync/live-transcription toggles, language and
/// transcript style, engine choice, and (when Soniox is selected) its extra
/// tuning options.
struct TranscriptionSettingsView: View {

    private var settings: DeliverySettings { DeliverySettings.shared }
    @State private var directory = SpeakerDirectory.shared
    @Environment(AppModel.self) private var model

    @State private var installedLocales: [Locale] = []
    @State private var sonioxKey = ""
    @State private var sonioxKeyError: String?
    @FocusState private var isSonioxKeyFocused: Bool

    var body: some View {
        Form {
            processingSection
            languageAndStyleSection
            engineSection
            if settings.transcriptionEngine == .soniox {
                sonioxLanguageHintsSection
                sonioxVocabularySection
                sonioxTranslationSection
            }
            knownSpeakersSection
        }
        .navigationTitle("Transcription & Engine")
        .toolbarTitleDisplayMode(.inline)
        .task {
            installedLocales = await LocalTranscriber.installedLocales()
            sonioxKey = Soniox.Credentials.apiKey ?? ""
        }
    }

    // MARK: - Processing

    private var processingSection: some View {
        Section {
            Toggle("Transcribe automatically on sync", isOn: Binding(
                get: { settings.transcribeOnSync },
                set: { settings.transcribeOnSync = $0 }
            ))
        } header: {
            Text("Processing")
        } footer: {
            Text("Automatically generates speech transcripts as soon as audio files finish syncing from your recorder.")
        }
    }

    // MARK: - Language & Style

    private var languageAndStyleSection: some View {
        Section {
            Picker("Primary language", selection: Binding(
                get: { settings.transcriptionLocaleIdentifier ?? "" },
                set: { settings.transcriptionLocaleIdentifier = $0.isEmpty ? nil : $0 }
            )) {
                Text("Match iPhone language").tag("")
                ForEach(installedLocales, id: \.identifier) { locale in
                    Text(locale.localizedString(forIdentifier: locale.identifier) ?? locale.identifier)
                        .tag(locale.identifier)
                }
            }

            Picker("Transcript format style", selection: Binding(
                get: { settings.transcriptFormat },
                set: { settings.transcriptFormat = $0 }
            )) {
                ForEach(TranscriptFormat.allCases) { Text($0.label).tag($0) }
            }
        } header: {
            Text("Language & Style")
        } footer: {
            Text("Applies to viewed, exported, and delivered transcripts. Markdown format creates notes with YAML frontmatter, executive summaries, and speaker labels optimized for note apps like Obsidian or Logseq.")
        }
    }

    // MARK: - Speech Recognition Engine

    private var engineSection: some View {
        Section {
            Picker("Speech engine", selection: Binding(
                get: { settings.transcriptionEngine },
                set: { settings.transcriptionEngine = $0 }
            )) {
                ForEach(TranscriptionEngine.allCases) { Text($0.label).tag($0) }
            }

            SecureField("Soniox API key", text: $sonioxKey)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .focused($isSonioxKeyFocused)
                .onSubmit { saveSonioxKey() }
                .onChange(of: isSonioxKeyFocused) { wasFocused, isFocused in
                    if wasFocused, !isFocused { saveSonioxKey() }
                }

            if let sonioxKeyError {
                Label(sonioxKeyError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if settings.transcriptionEngine == .soniox && !Soniox.Credentials.hasKey {
                Label("Enter an API key to enable Soniox cloud transcription. Bounce will fallback to local transcription if unavailable.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Link("Get API key at console.soniox.com",
                 destination: URL(string: "https://console.soniox.com")!)
                .font(.caption)
        } header: {
            Text("Speech recognition engine")
        } footer: {
            if settings.transcriptionEngine == .soniox {
                Text("Soniox uses cloud AI for high-accuracy multi-language transcription. Audio is transmitted securely to Soniox servers. Your API key is encrypted in your iPhone keychain.")
            } else {
                Text("Apple On-Device Speech processes everything locally on your iPhone. Audio files never leave your device.")
            }
        }
    }

    private func saveSonioxKey() {
        do {
            try Soniox.Credentials.save(sonioxKey)
            sonioxKeyError = nil
        } catch {
            sonioxKeyError = "Could not save API key: \(error.localizedDescription)"
        }
    }

    // MARK: - Soniox Cloud Tuning

    private var sonioxLanguageHintsSection: some View {
        Section {
            TextField("Language codes (e.g. en, es, fr)", text: Binding(
                get: { settings.sonioxLanguageHintsRaw },
                set: { settings.sonioxLanguageHintsRaw = $0 }
            ))
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
        } header: {
            Text("Language hints")
        } footer: {
            Text("Comma-separated language codes to guide recognition accuracy for multi-lingual speakers.")
        }
    }

    private var sonioxVocabularySection: some View {
        Section {
            TextField("Custom terms & jargon", text: Binding(
                get: { settings.sonioxVocabularyRaw },
                set: { settings.sonioxVocabularyRaw = $0 }
            ), axis: .vertical)
            .autocorrectionDisabled()
        } header: {
            Text("Custom vocabulary")
        } footer: {
            Text("Provide comma-separated industry terminology, product names, or acronyms to improve recognition precision.")
        }
    }

    private var sonioxTranslationSection: some View {
        Section {
            Picker("Live preview translation", selection: Binding(
                get: { settings.sonioxTranslationTarget },
                set: { settings.sonioxTranslationTarget = $0 }
            )) {
                Text("Off").tag("")
                ForEach(Self.translationLanguages, id: \.self) { code in
                    Text(Locale.current.localizedString(forLanguageCode: code) ?? code)
                        .tag(code)
                }
            }
        } header: {
            Text("Translation")
        } footer: {
            Text("Translates the live preview text in real-time. Final transcripts remain in the original spoken language.")
        }
    }

    // MARK: - Speaker Directory

    private var knownSpeakersSection: some View {
        Section {
            if directory.suggestions.isEmpty {
                Text("No saved speakers yet. Names entered when assigning speakers will appear here.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(directory.suggestions) { speaker in
                    HStack {
                        Text(speaker.name)
                        Spacer()
                        Text("\(speaker.useCount)×")
                            .font(.footnote)
                            .monospacedDigit()
                            .foregroundStyle(.tertiary)
                    }
                }
                .onDelete { offsets in
                    for index in offsets {
                        directory.forget(id: directory.suggestions[index].id)
                    }
                }
            }
        } header: {
            Text("Speaker directory")
        } footer: {
            Text("Saved speaker names are suggested when assigning voices in transcripts. Swipe to remove unused entries.")
        }
    }

    private static let translationLanguages = [
        "en", "es", "fr", "de", "it", "pt", "nl",
        "zh", "ja", "ko", "ar", "hi", "ru",
    ]
}
