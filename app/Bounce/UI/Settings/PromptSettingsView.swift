import SwiftUI

/// Every instruction Bounce sends to the on-device model, editable.
///
/// This is deliberately an advanced screen. Editing a prompt changes how well the
/// feature behind it works, and there is no way to validate "well" — a worse prompt
/// produces worse output silently. Two things keep that from being reckless:
///
/// - **Guided generation still enforces the output *shape*.** The classifier and the
///   action-item extractor use `@Generable`, so the framework guarantees the fields
///   come back regardless of what the prompt says. A bad prompt costs quality, not
///   stability, and it cannot corrupt stored data.
/// - **Nothing is destroyed.** Defaults live in code; an edit is an override, and
///   Reset removes it.
///
/// The real hazard is placeholders — see `PromptEditor`.
struct PromptSettingsView: View {

    @State private var store = PromptStore.shared
    @State private var isConfirmingResetAll = false

    var body: some View {
        Form {
            Section {
                ForEach(store.all) { prompt in
                    NavigationLink {
                        PromptEditor(promptId: prompt.id)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(prompt.name)
                                if store.isCustomised(prompt.id) {
                                    Text("Edited")
                                        .font(.caption2)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(.tint.opacity(0.14), in: .capsule)
                                }
                                Spacer()
                                // A missing placeholder is the one edit that breaks a
                                // prompt outright, so it's flagged in the list too —
                                // not only inside the editor the user has left.
                                if !store.missingPlaceholders(prompt.id).isEmpty {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundStyle(.orange)
                                }
                            }
                            Text(prompt.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("Prompts")
            } footer: {
                Text("These are the instructions Bounce sends to the on-device model. Editing one changes how that feature behaves \u{2014} for better or worse \u{2014} and there's no way for the app to tell which. Everything here can be put back.")
            }

            if store.all.contains(where: { store.isCustomised($0.id) }) {
                Section {
                    Button("Reset all prompts", role: .destructive) {
                        isConfirmingResetAll = true
                    }
                }
            }
        }
        .navigationTitle("Prompts")
        .toolbarTitleDisplayMode(.inline)
        .confirmationDialog(
            "Reset every prompt?",
            isPresented: $isConfirmingResetAll,
            titleVisibility: .visible
        ) {
            Button("Reset all", role: .destructive) { store.resetAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Discards your edits to every prompt and restores the shipped wording. Your summary templates and categories aren't affected.")
        }
    }
}

/// Edit one prompt.
///
/// **Placeholders are the thing that can actually break.** Each prompt interpolates
/// something — the transcript, the category list, the date anchor — and deleting one
/// doesn't error, it just sends the model an instruction with a hole in it. So the
/// required ones are listed, insertable by tap, and their absence is warned about
/// prominently. The warning does not *block* saving: someone restructuring a prompt
/// may legitimately have it in an inconsistent state mid-edit, and a settings screen
/// that refuses to save is worse than one that tells you what's wrong.
private struct PromptEditor: View {

    let promptId: String

    @State private var store = PromptStore.shared
    @State private var text = ""
    @State private var isLoaded = false
    @Environment(\.dismiss) private var dismiss

    private var prompt: EditablePrompt? { store.prompt(id: promptId) }

    /// Checked against the *draft*, not the saved text, so the warning tracks what's
    /// on screen rather than what was last committed.
    private var missing: [String] {
        prompt?.missingPlaceholders(in: text) ?? []
    }

    var body: some View {
        Form {
            if !missing.isEmpty {
                Section {
                    Label(
                        missing.count == 1
                            ? "\(missing[0]) is missing. Without it the model never sees that part of the recording."
                            : "\(missing.joined(separator: ", ")) are missing. Without them the model never sees those parts of the recording.",
                        systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }

            Section {
                TextEditor(text: $text)
                    .font(.callout.monospaced())
                    .frame(minHeight: 260)
                    .autocorrectionDisabled()
            } header: {
                Text(prompt?.name ?? "Prompt")
            } footer: {
                Text(prompt?.detail ?? "")
            }

            if let prompt, !prompt.allPlaceholders.isEmpty {
                Section {
                    ForEach(prompt.allPlaceholders, id: \.self) { name in
                        let token = PromptTemplating.token(name)
                        Button {
                            // Appended rather than inserted at the cursor: SwiftUI's
                            // TextEditor exposes no selection binding, and appending
                            // is predictable where a guessed position is not.
                            if !text.hasSuffix("\n") { text += "\n" }
                            text += token
                        } label: {
                            HStack {
                                Text(token).font(.callout.monospaced())
                                Spacer()
                                if prompt.requiredPlaceholders.contains(name) {
                                    Text("required").font(.caption2).foregroundStyle(.secondary)
                                }
                                Image(systemName: "plus.circle")
                            }
                        }
                    }
                } header: {
                    Text("Placeholders")
                } footer: {
                    Text("Bounce swaps these for the real values before sending. Anything it doesn't recognise is left in the prompt exactly as you typed it, so a typo shows up in the output rather than vanishing.")
                }
            }

            Section {
                Button("Reset to default") {
                    store.reset(promptId)
                    text = store.text(for: promptId)
                }
                .disabled(!store.isCustomised(promptId))
            }
        }
        .navigationTitle(prompt?.name ?? "Prompt")
        .toolbarTitleDisplayMode(.inline)
        .onAppear {
            guard !isLoaded else { return }
            isLoaded = true
            text = store.text(for: promptId)
        }
        // Saved on leaving rather than behind a Save button: this is a settings
        // screen, and every other editable value in Settings writes through. An
        // empty draft is treated as "reset", since an empty prompt is never intended.
        .onDisappear {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                store.reset(promptId)
            } else {
                store.update(promptId, to: text)
            }
        }
    }
}
