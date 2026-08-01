import SwiftUI

/// Settings screens for the auto-organize pass: the templates the AI can run
/// and the categories it classifies recordings into. Everything here drives
/// `AutoOrganizer`; edits write through to their stores immediately, matching
/// the rest of Settings.

// MARK: - AI settings root

/// The AI category page, reached from `SettingsView`: the auto-organize
/// toggle plus links into the category and template editors below.
struct AISettingsView: View {

    private var settings: DeliverySettings { DeliverySettings.shared }

    var body: some View {
        Form {
            Section {
                Toggle("Auto-organize recordings", isOn: Binding(
                    get: { settings.autoOrganize },
                    set: { settings.autoOrganize = $0 }
                ))

                NavigationLink("Smart Categories") { CategoryListView() }
                NavigationLink("Summary Templates") { TemplateListView() }
                NavigationLink("Custom Model Prompts") { PromptSettingsView() }
            } header: {
                Text("On-device AI Processing")
            } footer: {
                Text("After each transcription, Apple Intelligence picks a category, titles the recording (\u{201C}Meeting: Budget review\u{201D}) unless you've titled it yourself, and runs that category's summary templates \u{2014} all on this iPhone, before automatic delivery. Skipped on devices without Apple Intelligence.")
            }
        }
        .navigationTitle("AI & Intelligence")
        .toolbarTitleDisplayMode(.inline)
    }
}

// MARK: - Templates

/// All summary templates — built-ins and the user's own. Every one is
/// editable; edited built-ins can be reset to the shipped version.
struct TemplateListView: View {

    @State private var store = TemplateStore.shared
    @State private var isAdding = false

    var body: some View {
        Form {
            Section {
                ForEach(store.all) { template in
                    NavigationLink {
                        TemplateEditorView(templateId: template.id)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(template.name)
                                if template.runsAutomatically {
                                    Image(systemName: "sparkles")
                                        .font(.caption2)
                                        .foregroundStyle(.tint)
                                }
                            }
                            Text(template.prompt)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                }
            } footer: {
                Text("A template is an instruction the on-device model runs over a transcript. Templates marked \(Image(systemName: "sparkles")) run automatically for every new recording; categories can also run specific templates.")
            }

            Section {
                Button("New template", systemImage: "plus") {
                    isAdding = true
                }
                // Shown only when something is actually missing, mirroring how the
                // Tasks tab hides its scan action once there's nothing to scan. A
                // permanently-visible restore on a full list invites the question
                // "restore what?".
                if store.hasDeletedBuiltIns {
                    Button("Restore built-in templates") {
                        store.restoreStarterSet()
                    }
                }
            }
        }
        .navigationTitle("Templates")
        .toolbarTitleDisplayMode(.inline)
        .sheet(isPresented: $isAdding) {
            TemplateEditor { name, prompt in store.add(name: name, prompt: prompt) }
        }
    }
}

/// Edit any template — name, instruction, and whether it auto-runs. Built-ins
/// offer "Reset to default"; custom templates can be deleted.
struct TemplateEditorView: View {

    let templateId: String

    @Environment(\.dismiss) private var dismiss
    @State private var store = TemplateStore.shared
    @State private var name = ""
    @State private var prompt = ""
    @State private var autoRun = false
    @State private var isLoaded = false

    private var template: SummaryTemplate? { store.template(id: templateId) }

    var body: some View {
        Form {
            Section("Name") {
                TextField("Template name", text: $name)
            }
            Section {
                TextField("What the summary should do", text: $prompt, axis: .vertical)
                    .lineLimit(4...12)
            } header: {
                Text("Instruction")
            } footer: {
                Text("Runs over the transcript on device. Describe exactly what you want, e.g. \u{201C}List objections the customer raised and how they were handled.\u{201D}")
            }

            Section {
                Toggle("Run for every recording", isOn: $autoRun)
            } footer: {
                Text("Generates this summary automatically after each transcription, whatever the recording's category.")
            }

            if template?.isBuiltIn == true {
                Section {
                    Button("Reset to default") {
                        store.resetBuiltIn(id: templateId)
                        load()
                    }
                    .disabled(!store.isOverridden(id: templateId))
                } footer: {
                    Text("Restores this built-in template's shipped name and instruction.")
                }
                Section {
                    Button("Delete template", role: .destructive) {
                        store.remove(id: templateId)
                        dismiss()
                    }
                } footer: {
                    // Two separate controls with genuinely different effects, which
                    // is why they're in separate sections rather than one row each of
                    // an action list: Reset undoes *edits*, Delete removes the
                    // template. Deleting keeps the edits, so restoring gives back
                    // your version rather than the shipped one.
                    Text("Built-in templates can be brought back with “Restore built-in templates” on the Templates list. Your edits to this one are kept if you do.")
                }
            } else {
                Section {
                    Button("Delete template", role: .destructive) {
                        store.remove(id: templateId)
                        dismiss()
                    }
                }
            }
        }
        .navigationTitle(name.isEmpty ? "Template" : name)
        .toolbarTitleDisplayMode(.inline)
        .onAppear {
            guard !isLoaded else { return }
            isLoaded = true
            load()
        }
        .onChange(of: name) { save() }
        .onChange(of: prompt) { save() }
        .onChange(of: autoRun) { save() }
    }

    private func load() {
        guard let template else { return }
        name = template.name
        prompt = template.prompt
        autoRun = template.runsAutomatically
    }

    /// Write through on every change, like the rest of Settings — but never
    /// save an emptied name or instruction, so backspacing to zero can't wreck
    /// the template.
    private func save() {
        guard isLoaded, var template else { return }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !trimmedPrompt.isEmpty else { return }
        template.name = trimmedName
        template.prompt = trimmedPrompt
        template.autoRun = autoRun ? true : nil
        store.update(template)
    }
}

// MARK: - Categories

/// The user's recording categories — what the AI classifies each new recording
/// into. Fully user-defined: edit, delete, or add to the starter set.
struct CategoryListView: View {

    @State private var store = CategoryStore.shared
    @State private var isAdding = false

    var body: some View {
        Form {
            Section {
                ForEach(store.categories) { category in
                    NavigationLink {
                        CategoryEditorView(categoryId: category.id)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: CategoryStyle.symbol(for: category))
                                .font(.body)
                                .foregroundStyle(CategoryStyle.color(for: category))
                                .frame(width: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(category.name)
                                Text(category.guidance)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                    }
                }
            } footer: {
                Text(store.categories.isEmpty
                     ? "No categories: recordings are transcribed and summarized but not classified or auto-titled."
                     : "After each transcription, the AI picks the best-fitting category, prefixes the title (\u{201C}Meeting: Budget review\u{201D}) if you haven't titled the recording, and runs the category's templates.")
            }

            Section {
                Button("New category", systemImage: "plus") {
                    isAdding = true
                }
                Button("Restore starter categories") {
                    store.restoreStarterSet()
                }
            }
        }
        .navigationTitle("Categories")
        .toolbarTitleDisplayMode(.inline)
        .sheet(isPresented: $isAdding) {
            CategoryCreateSheet { store.add($0) }
        }
    }
}

/// Edit one category: its name, title prefix, the guidance that teaches the
/// classifier when it applies, and which templates auto-run for it.
struct CategoryEditorView: View {

    let categoryId: String

    @Environment(\.dismiss) private var dismiss
    @State private var store = CategoryStore.shared
    @State private var templates = TemplateStore.shared
    @State private var name = ""
    @State private var titlePrefix = ""
    @State private var guidance = ""
    @State private var templateIds: [String] = []
    @State private var colorName: String?
    @State private var symbolName: String?
    @State private var isLoaded = false

    var body: some View {
        Form {
            Section("Name") {
                TextField("e.g. Meeting", text: $name)
            }

            Section {
                CategoryAppearancePicker(colorName: $colorName, symbolName: $symbolName)
            } header: {
                Text("Appearance")
            } footer: {
                Text("How this category marks its recordings in the library.")
            }
            Section {
                TextField("e.g. Meeting:", text: $titlePrefix)
                    .autocorrectionDisabled()
            } header: {
                Text("Title prefix")
            } footer: {
                Text("Put before the AI title: \u{201C}Meeting: Budget review\u{201D}. Leave empty for no prefix.")
            }
            Section {
                TextField("When does this category apply?", text: $guidance, axis: .vertical)
                    .lineLimit(3...8)
            } header: {
                Text("When to use")
            } footer: {
                Text("Teaches the AI when a recording belongs here, e.g. \u{201C}The user reminds themself of something tied to a day or time.\u{201D}")
            }

            Section {
                ForEach(templates.all) { template in
                    Toggle(template.name, isOn: Binding(
                        get: { templateIds.contains(template.id) },
                        set: { isOn in
                            if isOn {
                                if !templateIds.contains(template.id) { templateIds.append(template.id) }
                            } else {
                                templateIds.removeAll { $0 == template.id }
                            }
                        }
                    ))
                }
            } header: {
                Text("Auto-run templates")
            } footer: {
                Text("These summaries are generated automatically for recordings in this category.")
            }

            Section {
                Button("Delete category", role: .destructive) {
                    store.remove(id: categoryId)
                    dismiss()
                }
            }
        }
        .navigationTitle(name.isEmpty ? "Category" : name)
        .toolbarTitleDisplayMode(.inline)
        .onAppear {
            guard !isLoaded, let category = store.category(id: categoryId) else { return }
            isLoaded = true
            name = category.name
            titlePrefix = category.titlePrefix
            guidance = category.guidance
            templateIds = category.templateIds
            colorName = category.colorName
            symbolName = category.symbolName
        }
        .onChange(of: name) { save() }
        .onChange(of: titlePrefix) { save() }
        .onChange(of: guidance) { save() }
        .onChange(of: templateIds) { save() }
        .onChange(of: colorName) { save() }
        .onChange(of: symbolName) { save() }
    }

    private func save() {
        guard isLoaded, var category = store.category(id: categoryId) else { return }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }
        category.name = trimmedName
        category.titlePrefix = titlePrefix.trimmingCharacters(in: .whitespacesAndNewlines)
        category.guidance = guidance.trimmingCharacters(in: .whitespacesAndNewlines)
        category.templateIds = templateIds
        category.colorName = colorName
        category.symbolName = symbolName
        store.update(category)
    }
}

/// Colour swatches and a glyph grid, shared by the category editor and the
/// create sheet. Both bindings are optional: nil means "unset", which resolves
/// to a stable fallback rather than to a specific stored choice.
private struct CategoryAppearancePicker: View {

    @Binding var colorName: String?
    @Binding var symbolName: String?

    private var tint: Color {
        CategoryStyle.swatches.first { $0.name == colorName }?.color ?? .secondary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                ForEach(CategoryStyle.swatches) { swatch in
                    Button {
                        colorName = swatch.name
                    } label: {
                        Circle()
                            .fill(swatch.color)
                            .frame(width: 26, height: 26)
                            .overlay {
                                if swatch.name == colorName {
                                    Image(systemName: "checkmark")
                                        .font(.caption.weight(.bold))
                                        .foregroundStyle(.white)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(swatch.name)
                    .accessibilityAddTraits(swatch.name == colorName ? [.isSelected] : [])
                }
            }
            .frame(maxWidth: .infinity)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 8), spacing: 10) {
                ForEach(CategoryStyle.symbols, id: \.self) { symbol in
                    Button {
                        symbolName = symbol
                    } label: {
                        Image(systemName: symbol)
                            .font(.body)
                            .foregroundStyle(symbol == symbolName ? AnyShapeStyle(tint) : AnyShapeStyle(.secondary))
                            .frame(width: 32, height: 32)
                            .background(
                                symbol == symbolName ? tint.opacity(0.18) : .clear,
                                in: .rect(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(symbol)
                    .accessibilityAddTraits(symbol == symbolName ? [.isSelected] : [])
                }
            }
        }
        .padding(.vertical, 4)
    }
}

/// Create a category: name, prefix, and guidance. Templates are picked
/// afterwards in the editor.
private struct CategoryCreateSheet: View {

    let onSave: (RecordingCategory) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var titlePrefix = ""
    @State private var guidance = ""
    @State private var colorName: String?
    @State private var symbolName: String?
    /// Tracks whether the prefix still follows the name, so typing a custom
    /// prefix stops the auto-suggestion.
    @State private var prefixEdited = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("e.g. Idea", text: $name)
                        .onChange(of: name) {
                            guard !prefixEdited else { return }
                            let trimmed = name.trimmingCharacters(in: .whitespaces)
                            titlePrefix = trimmed.isEmpty ? "" : "\(trimmed):"
                        }
                }
                Section("Title prefix") {
                    TextField("e.g. Idea:", text: $titlePrefix)
                        .autocorrectionDisabled()
                        .onChange(of: titlePrefix) { _, newValue in
                            let trimmed = name.trimmingCharacters(in: .whitespaces)
                            prefixEdited = newValue != (trimmed.isEmpty ? "" : "\(trimmed):")
                        }
                }
                Section {
                    TextField("When does this category apply?", text: $guidance, axis: .vertical)
                        .lineLimit(3...8)
                } header: {
                    Text("When to use")
                }
                Section {
                    CategoryAppearancePicker(colorName: $colorName, symbolName: $symbolName)
                } header: {
                    Text("Appearance")
                } footer: {
                    Text("Optional — a category with no appearance picked still gets a consistent colour of its own.")
                }
            }
            .navigationTitle("New category")
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(RecordingCategory(
                            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                            titlePrefix: titlePrefix.trimmingCharacters(in: .whitespacesAndNewlines),
                            guidance: guidance.trimmingCharacters(in: .whitespacesAndNewlines),
                            colorName: colorName,
                            symbolName: symbolName))
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty
                        || guidance.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}
