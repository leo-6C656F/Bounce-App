import SwiftUI

/// Every action item across the library, grouped by the recording it came from.
///
/// The items themselves are extracted per recording by `AutoOrganizer` and
/// stored on `Recording.actionItems`; this is a second presentation over that
/// same data, not a separate store. Grouped by recording rather than flattened,
/// because an action divorced from the conversation it came from is hard to act
/// on — and tapping through to the recording, seeked to where it was said, is
/// the point.
///
/// The grouping is unchanged from the first version; what changed is that a
/// group now looks like the recording it belongs to. A bare uppercase title over
/// a white box gave no clue which recording it was, and made a one-task
/// recording cost a header as tall as the task under it.
struct TasksView: View {

    @Environment(AppModel.self) private var model

    enum TaskFilterMode: String, CaseIterable, Identifiable {
        case pending = "Open"
        case completed = "Done"
        case all = "All"

        var id: String { rawValue }
    }

    @State private var filterMode: TaskFilterMode = .pending
    @State private var searchText = ""
    @State private var isAdding = false
    @State private var draftText = ""
    /// Which recording a hand-added item belongs to.
    @State private var addTarget: Recording?
    /// Shown when the user tries to send a task with no destination switched on.
    @State private var isShowingNoDestinationHint = false

    private var transcribedRecordings: [Recording] {
        model.recordings.filter(\.isTranscribed)
    }

    var body: some View {
        NavigationStack {
            Group {
                if groups.isEmpty { emptyState } else { list }
            }
            .navigationTitle("Tasks")
            .searchable(text: $searchText, prompt: "Search tasks")
            .safeAreaBar(edge: .top) { filterBar }
            .safeAreaInset(edge: .bottom) { scanProgress }
            .toolbar { toolbarContent }
            .alert("New task", isPresented: $isAdding) {
                TextField("What needs doing", text: $draftText)
                Button("Add") {
                    if let addTarget { model.addActionItem(draftText, to: addTarget) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(addTarget.map { "Added to “\($0.displayTitle)”." } ?? "")
            }
            .alert("No destination turned on", isPresented: $isShowingNoDestinationHint) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Turn on Apple Reminders, Apple Calendar, or a task webhook in Settings › Integrations & Delivery, then send the task again.")
            }
            // The outcome of an explicit Send to Reminders — a plain confirmation
            // ("Added N to Reminders") or a clear failure with what to do about it.
            // Replaces the old silent no-op when the target list had been deleted.
            .alert(
                model.taskSendResult?.title ?? "",
                isPresented: Binding(
                    get: { model.taskSendResult != nil },
                    set: { if !$0 { model.taskSendResult = nil } }),
                presenting: model.taskSendResult
            ) { _ in
                Button("OK", role: .cancel) {}
            } message: { result in
                Text(result.body)
            }
        }
    }

    /// Send tasks to whatever destinations are enabled, or nudge to Settings when
    /// none are.
    ///
    /// The gesture that replaces the old auto-add: a task is a proposal until the
    /// user sends it. When nothing is enabled the approval is deliberately *not*
    /// recorded — a task shown as "Sent" that reached nowhere would be a lie — so
    /// the user is pointed at Settings and can send again once a destination is on.
    private func send(_ items: [ActionItem], in recording: Recording) {
        let sendable = items.filter { !$0.isDone && !$0.pushRequested }
        guard !sendable.isEmpty else { return }
        guard model.hasEnabledTaskDestination else {
            isShowingNoDestinationHint = true
            return
        }
        Task { await model.pushActionItems(sendable, in: recording) }
    }

    // MARK: - Chrome

    /// Chips rather than a segmented control, matching the Library's category
    /// filters — the two screens filter the same library and shouldn't use two
    /// different controls to say so. The count rides on the active chip so the
    /// header doesn't need a second line to report it.
    private var filterBar: some View {
        HStack(spacing: 8) {
            ForEach(TaskFilterMode.allCases) { mode in
                let isActive = filterMode == mode
                Button {
                    filterMode = mode
                } label: {
                    HStack(spacing: 6) {
                        Text(mode.rawValue)
                        if isActive, count(for: mode) > 0 {
                            Text("\(count(for: mode))")
                                .monospacedDigit()
                                .opacity(0.7)
                        }
                    }
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
                .foregroundStyle(isActive ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                .background(
                    isActive ? AnyShapeStyle(.tint) : AnyShapeStyle(.background.secondary),
                    in: .capsule)
                .accessibilityAddTraits(isActive ? [.isSelected] : [])
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
    }

    private func count(for mode: TaskFilterMode) -> Int {
        let all = model.allActionItems
        switch mode {
        case .pending: return all.filter { !$0.item.isDone }.count
        case .completed: return all.filter { $0.item.isDone }.count
        case .all: return all.count
        }
    }

    @ViewBuilder
    private var scanProgress: some View {
        if let scan = model.actionItemScan {
            VStack(spacing: 6) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Reading recording \(scan.done + 1) of \(scan.total)…")
                        .font(.footnote)
                    Spacer()
                }
                ProgressView(value: Double(scan.done), total: Double(max(scan.total, 1)))
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.bar)
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if let newest = transcribedRecordings.first {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Section("Add task to recent recording") {
                        ForEach(transcribedRecordings.prefix(8)) { recording in
                            Button(recording.displayTitle) {
                                addTarget = recording
                                draftText = ""
                                isAdding = true
                            }
                        }
                    }
                } label: {
                    Label("Add task", systemImage: "plus")
                } primaryAction: {
                    addTarget = newest
                    draftText = ""
                    isAdding = true
                }
            }
        }

        ToolbarItem(placement: .topBarTrailing) {
            let pending = model.recordingsNeedingActionItemScan
            if pending > 0, model.actionItemScan == nil {
                Button {
                    model.scanForActionItems()
                } label: {
                    Label("Scan older recordings", systemImage: "sparkles.rectangle.stack")
                }
            }
        }
    }

    // MARK: - List

    private var list: some View {
        List {
            ForEach(groups, id: \.recording.id) { group in
                Section {
                    ForEach(group.items) { item in
                        NavigationLink {
                            RecordingDetailView(recording: group.recording)
                        } label: {
                            row(item, in: group.recording)
                        }
                        .swipeActions(edge: .trailing) {
                            Button("Delete", systemImage: "trash", role: .destructive) {
                                model.deleteActionItem(item, in: group.recording)
                            }
                            // Only an open task that hasn't been sent yet can be
                            // sent — a done one has nothing to chase, and a sent one
                            // is already linked and reconciled on its own.
                            if !item.isDone, !item.pushRequested {
                                Button("Send", systemImage: "paperplane") {
                                    send([item], in: group.recording)
                                }
                                .tint(.blue)
                            }
                        }
                        .swipeActions(edge: .leading) {
                            Button(item.isDone ? "Reopen" : "Done", systemImage: item.isDone ? "arrow.uturn.backward" : "checkmark") {
                                model.setActionItem(item, in: group.recording, done: !item.isDone)
                            }
                            .tint(item.isDone ? .orange : .green)
                        }
                    }
                } header: {
                    header(for: group)
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollEdgeEffectStyle(.soft, for: .top)
    }

    /// The recording a group of tasks came from, rendered as the recording
    /// rather than as a caption: its category glyph, its title in sentence case,
    /// and how much of it is left.
    private func header(for group: RecordingTasks) -> some View {
        HStack(spacing: 10) {
            CategoryGlyph(categoryName: group.recording.categoryName)

            VStack(alignment: .leading, spacing: 1) {
                Text(group.recording.displayTitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(group.recording.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            if group.total > 0, group.done > 0 {
                StatusChip(text: "\(group.done)/\(group.total)", tint: .accentColor)
            }

            // Send every open, not-yet-sent task in this recording at once. Hidden
            // in the Done filter, where the sendable tasks aren't even on screen.
            let sendable = sendableItems(in: group.recording)
            if filterMode != .completed, !sendable.isEmpty {
                Button {
                    send(sendable, in: group.recording)
                } label: {
                    Label(
                        sendable.count == 1 ? "Send" : "Send \(sendable.count)",
                        systemImage: "paperplane")
                        .font(.caption.weight(.semibold))
                        .textCase(nil)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Send \(sendable.count) task\(sendable.count == 1 ? "" : "s") from \(group.recording.displayTitle)")
            }
        }
        .textCase(nil)
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
    }

    /// The open, not-yet-sent tasks on a recording — what "Send all" acts on.
    /// Computed over the full list, not the filtered slice, so the count is the
    /// recording's real backlog rather than what a search happens to show.
    private func sendableItems(in recording: Recording) -> [ActionItem] {
        (recording.actionItems ?? []).filter { !$0.isDone && !$0.pushRequested }
    }

    private func row(_ item: ActionItem, in recording: Recording) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Button {
                model.setActionItem(item, in: recording, done: !item.isDone)
            } label: {
                Image(systemName: item.isDone ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(item.isDone ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                    .contentTransition(.symbolEffect(.replace))
                    .symbolEffect(.bounce, value: item.isDone)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(item.isDone ? "Mark as not done" : "Mark as done")

            VStack(alignment: .leading, spacing: 4) {
                Text(item.text)
                    .strikethrough(item.isDone)
                    .foregroundStyle(item.isDone ? .secondary : .primary)

                HStack(spacing: 8) {
                    if let detail = item.detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    // Where it was said. A timecode is the fastest way back into
                    // the conversation, and it is the whole reason these stay
                    // grouped by recording.
                    if let offset = item.sourceOffset {
                        Text(offset.timecodeText)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.tint)
                            .accessibilityLabel("said at \(offset.spokenTimecode)")
                    }
                    // Once a task has been sent it carries this badge, so the list
                    // distinguishes candidates the user still has to review from the
                    // ones already on their way to Reminders/Calendar/a webhook.
                    if item.pushRequested {
                        Label("Sent", systemImage: "paperplane.fill")
                            .labelStyle(.titleAndIcon)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.blue)
                            .accessibilityLabel("Sent to your task destinations")
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if !searchText.isEmpty {
            EmptyHint(
                symbol: "magnifyingglass",
                title: "No tasks found",
                message: "No action items match “\(searchText)”.")
        } else if model.allActionItems.isEmpty {
            EmptyHint(
                symbol: "checklist",
                title: "No tasks yet",
                message: "Bounce pulls action items out of your recordings after transcribing them. You can also add one using the + button.")
        } else {
            EmptyHint(
                symbol: filterMode == .completed ? "checkmark.circle" : "checklist.checked",
                title: filterMode == .completed ? "No completed tasks" : "All caught up!",
                message: filterMode == .completed ? "Tasks you complete will show up here." : "No open action items right now.")
        }
    }

    // MARK: - Grouping

    struct RecordingTasks {
        let recording: Recording
        let items: [ActionItem]
        /// Counted over **all** the recording's items, not the filtered slice —
        /// "2/5" has to mean two of the recording's five, or the chip reads as
        /// "2 of the 2 currently shown" and never moves.
        let done: Int
        let total: Int
    }

    private var groups: [RecordingTasks] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        return model.recordings.compactMap { recording in
            let all = recording.actionItems ?? []
            let items = all.filter { item in
                switch filterMode {
                case .pending: if item.isDone { return false }
                case .completed: if !item.isDone { return false }
                case .all: break
                }

                if !query.isEmpty {
                    let matchesText = item.text.lowercased().contains(query)
                    let matchesDetail = item.detail?.lowercased().contains(query) ?? false
                    return matchesText || matchesDetail
                }

                return true
            }
            guard !items.isEmpty else { return nil }
            return RecordingTasks(
                recording: recording,
                items: items,
                done: all.filter(\.isDone).count,
                total: all.count)
        }
    }
}
