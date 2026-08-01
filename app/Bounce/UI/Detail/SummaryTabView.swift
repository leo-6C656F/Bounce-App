import SwiftUI

/// The Summary tab as a document: the summaries that exist, one after another,
/// and a single control for adding one that doesn't.
///
/// **Templates that haven't run are not sections.** This used to render one card
/// per template in `TemplateStore.all` regardless, so a recording whose category
/// ran a single template opened on three ~150pt boxes containing nothing but a
/// Generate button, stacked above the one card with content in it. Furniture and
/// substance had identical visual weight, and the furniture came first.
///
/// So: content is a section, and everything ungenerated collapses into one
/// "Add a summary" row whose menu lists what's left. The page grows as you use
/// it rather than starting full of promises.
struct SummaryTabView: View {

    let recording: Recording

    @State private var generator = SummaryGenerator()
    @State private var store = TemplateStore.shared
    /// Template currently generating, and its streaming text.
    @State private var generatingId: String?
    @State private var streamText = ""
    @State private var generateTask: Task<Void, Never>?
    @State private var isAddingTemplate = false
    @State private var copiedTemplateId: String?

    private var current: Recording { RecordingStore.shared.recording(id: recording.id) ?? recording }

    /// Templates with a stored result, in the store's order so the document
    /// doesn't reshuffle as summaries are added.
    private var written: [(template: SummaryTemplate, summary: Summary)] {
        store.all.compactMap { template in
            guard let summary = current.summaries?.first(where: { $0.templateId == template.id })
            else { return nil }
            return (template, summary)
        }
    }

    private var unwritten: [SummaryTemplate] {
        store.all.filter { template in
            current.summaries?.contains { $0.templateId == template.id } != true
        }
    }

    var body: some View {
        if current.transcript == nil {
            ContentUnavailableView(
                "No transcript yet",
                systemImage: "doc.text.magnifyingglass",
                description: Text("Transcribe this recording to summarize it."))
                .padding(.top, 40)
        } else {
            switch generator.readiness {
            case .unavailable(let reason):
                ContentUnavailableView {
                    Label("Summaries unavailable", systemImage: "sparkles")
                } description: {
                    Text(reason)
                }
            case .ready:
                document
            }
        }
    }

    private var document: some View {
        VStack(alignment: .leading, spacing: 22) {
            ForEach(written, id: \.template.id) { entry in
                section(entry.template, text: entry.summary.text, createdAt: entry.summary.createdAt)
                Divider()
            }

            // The one still running, shown in place rather than as a spinner
            // somewhere else — it's about to become a section, so it appears as
            // one and fills in.
            if let generatingId, let template = store.template(id: generatingId) {
                streamingSection(template)
                Divider()
            }

            addRow

            Text("Written on device by Apple Intelligence from this recording's transcript. Nothing is uploaded. Long recordings are summarized from their most recent portion.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(isPresented: $isAddingTemplate) {
            TemplateEditor { name, prompt in store.add(name: name, prompt: prompt) }
        }
    }

    // MARK: - Sections

    private func section(_ template: SummaryTemplate, text: String, createdAt: Date) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                SectionLabel(template.name)
                Spacer(minLength: 0)

                Button {
                    generate(template)
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                .disabled(generatingId != nil)
                .accessibilityLabel("Regenerate \(template.name)")

                Button {
                    UIPasteboard.general.string = text
                    copiedTemplateId = template.id
                    Task {
                        try? await Task.sleep(for: .seconds(2))
                        if copiedTemplateId == template.id { copiedTemplateId = nil }
                    }
                } label: {
                    Image(systemName: copiedTemplateId == template.id ? "checkmark" : "doc.on.doc")
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                .accessibilityLabel("Copy \(template.name)")

                if !template.isBuiltIn {
                    Menu {
                        Button("Delete template", systemImage: "trash", role: .destructive) {
                            store.remove(id: template.id)
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }

            Text(text)
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)

            Text("Generated on device · \(createdAt.formatted(date: .omitted, time: .shortened))")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private func streamingSection(_ template: SummaryTemplate) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                SectionLabel(template.name, tint: .accentColor)
                ProgressView().controlSize(.mini)
                Spacer(minLength: 0)
            }

            if streamText.isEmpty {
                Text("Summarizing…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Text(streamText)
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - Add

    /// One row in place of a stack of empty cards. Its menu carries what's left
    /// to run, a run-everything shortcut, and the escape hatch to a new template.
    @ViewBuilder
    private var addRow: some View {
        if unwritten.isEmpty {
            Button {
                isAddingTemplate = true
            } label: {
                Label("New template", systemImage: "plus")
                    .font(.subheadline.weight(.medium))
            }
            .buttonStyle(.glass)
            .controlSize(.small)
        } else {
            Menu {
                ForEach(unwritten) { template in
                    Button(template.name, systemImage: "sparkles") { generate(template) }
                }
                if unwritten.count > 1 {
                    Divider()
                    Button("Run all \(unwritten.count)", systemImage: "sparkles") {
                        generateAll(unwritten)
                    }
                }
                Divider()
                Button("New template…", systemImage: "plus") { isAddingTemplate = true }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "plus")
                        .font(.body.weight(.medium))
                    Text("Add a summary")
                        .font(.subheadline.weight(.medium))
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                }
                .foregroundStyle(.tint)
                .padding(.horizontal, 16)
                .padding(.vertical, 13)
                .frame(maxWidth: .infinity)
                .background(.background.secondary, in: .rect(cornerRadius: Metrics.fieldRadius))
            }
            .disabled(generatingId != nil)
        }
    }

    // MARK: - Generation

    private func generate(_ template: SummaryTemplate) {
        generateAll([template])
    }

    /// Run templates one at a time, writing each as it finishes.
    ///
    /// **Serial, and that isn't a simplification.** Each run is a
    /// `LanguageModelSession` over the same transcript; firing several at once
    /// contends for the one on-device model, and `generatingId`/`streamText` can
    /// only describe a single run, so a concurrent version would render the
    /// wrong partial text under the wrong heading.
    private func generateAll(_ templates: [SummaryTemplate]) {
        guard generatingId == nil, let transcript = current.transcript?.plainText else { return }
        generateTask?.cancel()
        generateTask = Task {
            for template in templates {
                if Task.isCancelled { break }
                generatingId = template.id
                streamText = ""
                var final = ""
                for await partial in generator.generate(transcript: transcript, template: template) {
                    streamText = partial
                    final = partial
                }
                // A failed run yields its apology text into the stream so it can
                // be read inline; persisting that would store "Couldn't generate
                // this summary…" as a real summary and deliver it onward.
                if generator.lastError == nil, !final.isEmpty {
                    let summary = Summary(
                        templateId: template.id,
                        templateName: template.name,
                        text: final,
                        createdAt: Date())
                    RecordingStore.shared.update(id: recording.id) { rec in
                        var list = rec.summaries ?? []
                        list.removeAll { $0.templateId == template.id }
                        list.append(summary)
                        rec.summaries = list
                    }
                    // Republish, or the write is invisible to everything reading
                    // `AppModel.recordings` — the desktop client's library
                    // fingerprint among them. Same rule as every other store write.
                    SyncManager.shared.refreshLibrary()
                }
            }
            generatingId = nil
            streamText = ""
        }
    }
}

/// Create a custom template: a name and the instruction the model follows.
/// Shared with the Settings templates screen.
struct TemplateEditor: View {

    let onSave: (String, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var prompt = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("e.g. Sales call recap", text: $name)
                }
                Section {
                    TextField("What the summary should do", text: $prompt, axis: .vertical)
                        .lineLimit(4...10)
                } header: {
                    Text("Instruction")
                } footer: {
                    Text("Describe what you want, e.g. \u{201C}List objections the customer raised and how they were handled.\u{201D} It runs over the transcript on device.")
                }
            }
            .navigationTitle("New template")
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(name, prompt)
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty
                        || prompt.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}
