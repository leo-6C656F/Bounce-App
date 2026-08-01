import SwiftUI

/// Everything on this phone, grouped by day.
struct LibraryView: View {

    @Environment(AppModel.self) private var model
    @State private var searchText = ""
    @State private var filter: Filter = .all
    /// Category *name*, matching `Recording.categoryName`. Nil is "all".
    @State private var categoryFilter: String?
    /// Selected tag **ids**. Empty is "all". Intersection semantics — a recording
    /// must carry every selected tag, which is what the board request asked for and
    /// is the reason tags beat folders: one recording can satisfy several at once.
    @State private var tagFilter: Set<String> = []
    @State private var categories = CategoryStore.shared
    /// List or month grid. **View state, not a setting** — `DeliverySettings` is
    /// for delivery preferences, not a general preferences bag, so this
    /// deliberately resets when the tab is rebuilt.
    @State private var viewMode: ViewMode = .timeline
    /// The day the calendar has selected, as a `startOfDay`. Nil is "every day".
    @State private var selectedDay: Date?
    /// Ties a row to the detail screen it pushes, so the push zooms out of the
    /// row. One namespace for the whole tab: the list and the calendar are
    /// mutually exclusive modes of the same `NavigationStack`, so a recording is
    /// only ever a source in one of them at a time.
    @Namespace private var zoom

    /// Where the map's selection pushes to. Nil the rest of the time.
    ///
    /// The map can't hold a `NavigationLink` per marker — `Marker` is map
    /// content, not a view — so selection drives a programmatic push instead.
    @State private var mapDestination: Recording?

    /// The recording the "Join with…" sheet opened from, and which it
    /// pre-selects. Nil the rest of the time.
    @State private var mergeAnchor: Recording?

    enum ViewMode: String, CaseIterable, Identifiable {
        /// The default. Same recordings as `.list`, but each one's bar height is
        /// its duration, so the shape of a day is visible rather than inferred
        /// from reading every row's length text.
        case timeline, list, calendar, map, series

        var id: String { rawValue }

        var label: String {
            switch self {
            case .timeline: return "Timeline"
            case .list: return "List"
            case .calendar: return "Calendar"
            case .map: return "Map"
            case .series: return "Series"
            }
        }

        var symbol: String {
            switch self {
            case .timeline: return "chart.bar.doc.horizontal"
            case .list: return "list.bullet"
            case .calendar: return "calendar"
            case .map: return "map"
            case .series: return "repeat"
            }
        }
    }

    enum Filter: String, CaseIterable, Identifiable {
        case all, transcribed, pending

        var id: String { rawValue }

        var label: String {
            switch self {
            case .all: return "All"
            case .transcribed: return "Transcribed"
            case .pending: return "Not yet"
            }
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                switch viewMode {
                case .timeline:
                    if groups.isEmpty {
                        emptyState
                    } else {
                        RecordingTimeline(
                            groups: groups,
                            zoom: zoom,
                            onDelete: { model.delete($0) },
                            onTranscribe: { model.transcribe($0) })
                    }
                case .list:
                    if groups.isEmpty { emptyState } else { list }
                case .calendar:
                    calendarMode
                case .map:
                    RecordingMap(recordings: filtered) { mapDestination = $0 }
                case .series:
                    // Deliberately unfiltered. The other three modes index
                    // recordings, and the filters narrow which ones; this indexes
                    // *series*, and hiding one because none of its sessions match
                    // the current search would read as the series having been
                    // deleted.
                    SeriesListView()
                }
            }
            .navigationDestination(item: $mapDestination) { recording in
                RecordingDetailView(recording: recording)
            }
            // On the stack rather than on a row, because the action is offered
            // from both the list and the calendar and a sheet attached to a row
            // dies with the row when the library republishes mid-merge.
            .sheet(item: $mergeAnchor) { recording in
                MergeRecordingsSheet(anchor: recording)
            }
            .navigationTitle("Library")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { viewModeButton }
                if !categories.categories.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) { categoryMenu }
                }
            }
            .safeAreaBar(edge: .top) {
                categoryChips
            }
            .searchable(text: $searchText, prompt: "Search transcripts")
            .searchScopes($filter) {
                ForEach(Filter.allCases) { Text($0.label).tag($0) }
            }
            .searchToolbarBehavior(.minimize)
            .task {
                // Build waveform envelopes for the head of the library in the
                // background, once per launch, one at a time. Rows only read the
                // cache, so without this a sparkline would only ever appear for
                // recordings the user had already opened.
                await WaveformCache.shared.prewarm(
                    model.recordings.compactMap { RecordingStore.shared.audioURL(for: $0) })
            }
        }
    }

    @ViewBuilder
    private var categoryChips: some View {
        if !categories.categories.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    Button {
                        categoryFilter = nil
                    } label: {
                        Text("All")
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(categoryFilter == nil ? AnyShapeStyle(.tint) : AnyShapeStyle(.background.secondary), in: .capsule)
                            .foregroundStyle(categoryFilter == nil ? .white : .primary)
                    }
                    .buttonStyle(.plain)

                    ForEach(categories.categories) { cat in
                        let isSelected = (categoryFilter?.compare(cat.name, options: .caseInsensitive) == .orderedSame)
                        Button {
                            categoryFilter = isSelected ? nil : cat.name
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: CategoryStyle.symbol(for: cat))
                                    .font(.caption2)
                                Text(cat.name)
                                    .font(.caption.weight(.medium))
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.background.secondary), in: .capsule)
                            .foregroundStyle(isSelected ? .white : .primary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 6)
            }
        }
    }

    /// Category filtering lives in its own toolbar menu rather than in
    /// `.searchScopes`: the scopes already carry the transcription-state axis,
    /// and folding a user-defined, unbounded list into a segmented control that
    /// only fits three or four items would break as soon as someone adds a fifth
    /// category.
    private var categoryMenu: some View {
        Menu {
            Picker("Category", selection: $categoryFilter) {
                Text("All categories").tag(String?.none)
                ForEach(categories.categories) { category in
                    Label(category.name, systemImage: CategoryStyle.symbol(for: category))
                        .tag(String?.some(category.name))
                }
            }

            // Tags are a separate, multi-select axis rather than more entries in the
            // Picker above: the category axis is single-select (a recording has one
            // AI-assigned category) and tags are an intersection of several, so
            // folding them together would misrepresent both.
            Divider()
            Section("Tags") {
                ForEach(categories.categories) { tag in
                    Button {
                        if tagFilter.contains(tag.id) {
                            tagFilter.remove(tag.id)
                        } else {
                            tagFilter.insert(tag.id)
                        }
                    } label: {
                        Label(
                            tag.name,
                            systemImage: tagFilter.contains(tag.id)
                                ? "checkmark.circle.fill"
                                : CategoryStyle.symbol(for: tag))
                    }
                }
                if !tagFilter.isEmpty {
                    Button("Clear tags", systemImage: "xmark.circle") { tagFilter.removeAll() }
                }
            }
        } label: {
            Label(
                "Filter by category",
                systemImage: categoryFilter == nil
                    ? "line.3.horizontal.decrease.circle"
                    : "line.3.horizontal.decrease.circle.fill")
        }
    }

    /// Chooses between the list, the month grid and the map.
    ///
    /// This was a single toggling button while there were exactly two modes. A
    /// third makes a toggle unusable — the button can only name one destination,
    /// so the third is reachable only by cycling through the second — so it's a
    /// menu now. Still **not** a segmented `Picker`: on iOS 26 adjacent toolbar
    /// items merge into one glass capsule, and a three-segment picker beside the
    /// category menu reads as one four-part control that it isn't.
    private var viewModeButton: some View {
        Menu {
            Picker("View", selection: $viewMode) {
                ForEach(ViewMode.allCases) { mode in
                    Label(mode.label, systemImage: mode.symbol).tag(mode)
                }
            }
        } label: {
            Label("Change view", systemImage: viewMode.symbol)
        }
        .onChange(of: viewMode) { _, mode in
            // Leaving a stale day selected on the way out of the calendar would
            // silently filter the other modes, with no visible control
            // explaining why.
            if mode != .calendar { selectedDay = nil }
        }
    }

    // MARK: - Calendar mode

    /// The month grid above the day's recordings.
    ///
    /// Scrolls as one surface rather than pinning the grid, so a day with many
    /// recordings can use the whole screen — the grid is a control the user has
    /// just finished using, not chrome they need in view constantly.
    private var calendarMode: some View {
        ScrollView {
            VStack(spacing: Metrics.sectionSpacing) {
                CalendarGrid(
                    countsByDay: countsByDay,
                    selectedDay: $selectedDay)

                if filtered.isEmpty {
                    emptyState
                        .padding(.top, 12)
                } else {
                    ForEach(groups, id: \.day) { group in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(group.title)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            ForEach(group.recordings) { recording in
                                NavigationLink {
                                    RecordingDetailView(
                                        recording: recording,
                                        zoomSource: ZoomTransitionSource(id: recording.id, namespace: zoom))
                                } label: {
                                    RecordingRow(recording: recording)
                                }
                                .buttonStyle(.plain)
                                .matchedTransitionSource(id: recording.id, in: zoom)
                                .contextMenu { contextActions(for: recording) }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
    }

    /// Recording counts per day, for the grid's dots.
    ///
    /// Computed once here rather than inside each cell body — the grid takes a
    /// dictionary precisely so 42 cells don't each scan the library.
    ///
    /// Built from the *other* filters but **not** from `selectedDay`: the dots
    /// have to keep showing every day that has recordings, or selecting a day
    /// would erase every other day's dot and there would be no way to navigate
    /// back.
    private var countsByDay: [Date: Int] {
        CalendarGrid.countsByDay(for: matching(ignoringSelectedDay: true).map(\.createdAt))
    }

    // MARK: - List

    private var list: some View {
        List {
            ForEach(groups, id: \.day) { group in
                Section(group.title) {
                    ForEach(group.recordings) { recording in
                        NavigationLink {
                            RecordingDetailView(
                                recording: recording,
                                zoomSource: ZoomTransitionSource(id: recording.id, namespace: zoom))
                        } label: {
                            RecordingRow(recording: recording)
                        }
                        // Ahead of the swipe actions, so the zoom starts from the
                        // row's own bounds rather than from whatever the swipe
                        // container reports.
                        .matchedTransitionSource(id: recording.id, in: zoom)
                        .swipeActions(edge: .trailing) {
                            Button("Delete", systemImage: "trash", role: .destructive) {
                                model.delete(recording)
                            }
                        }
                        .swipeActions(edge: .leading) {
                            if recording.isSynced, !recording.isTranscribed {
                                Button("Transcribe", systemImage: "text.quote") {
                                    model.transcribe(recording)
                                }
                                .tint(.accentColor)
                            }
                        }
                        .contextMenu {
                            contextActions(for: recording)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollEdgeEffectStyle(.soft, for: .top)
    }

    @ViewBuilder
    private func contextActions(for recording: Recording) -> some View {
        if recording.isSynced, !recording.isTranscribed {
            Button("Transcribe", systemImage: "text.quote") {
                model.transcribe(recording)
            }
        }
        if RecordingMerge.canMerge(recording) {
            Button("Join with…", systemImage: "arrow.triangle.merge") {
                mergeAnchor = recording
            }
        }
        ForEach(DeliverySettings.shared.activeDestinations) { destination in
            Button("Send to \(destination.label)", systemImage: destination.symbolName) {
                model.send(recording, to: destination)
            }
        }
        Divider()
        Button("Delete", systemImage: "trash", role: .destructive) {
            model.delete(recording)
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if !searchText.isEmpty {
            EmptyHint(
                symbol: "magnifyingglass",
                title: "No matches",
                message: "Nothing in your transcripts matches “\(searchText)”.")
        } else if let selectedDay {
            // Same reasoning as the category case below: an unqualified "No
            // recordings" under an active day filter reads as data loss.
            EmptyHint(
                symbol: "calendar.badge.exclamationmark",
                title: "Nothing on \(selectedDay.formatted(.dateTime.weekday(.wide).day().month(.wide)))",
                message: "Tap the day again to see every recording.")
        } else if !tagFilter.isEmpty {
            // Names the tags, because intersection semantics are easy to
            // mis-predict: two tags that each match plenty of recordings can share
            // none, and an unqualified "No recordings" makes that look like a bug.
            EmptyHint(
                symbol: "tag",
                title: "Nothing tagged with all of these",
                message: "No recording carries \(activeTagNames). Tags filter to recordings that have every one you pick — remove one to widen the search.")
        } else if let categoryFilter {
            // Distinguished from a genuinely empty library, or the filter looks
            // like the app has lost the user's recordings.
            EmptyHint(
                symbol: "line.3.horizontal.decrease.circle",
                title: "Nothing in \(categoryFilter)",
                message: "No recordings are classified as “\(categoryFilter)”. Clear the filter to see everything.")
        } else {
            EmptyHint(
                symbol: "square.stack",
                title: "No recordings",
                message: "Recordings you sync from your Plaud device land here.")
        }
    }

    // MARK: - Grouping

    /// The selected tags' names, for the empty state. Resolved through the store so
    /// an id that somehow outlived its tag is dropped rather than printed raw.
    private var activeTagNames: String {
        let names = categories.categories
            .filter { tagFilter.contains($0.id) }
            .map { "“\($0.name)”" }
        guard names.count > 1, let last = names.last else { return names.first ?? "those tags" }
        return names.dropLast().joined(separator: ", ") + " and " + last
    }

    private var filtered: [Recording] { matching(ignoringSelectedDay: false) }

    /// The filter pipeline.
    ///
    /// `ignoringSelectedDay` exists for the calendar's dots: they are built from
    /// everything the other filters admit, because a day-scoped count would leave
    /// exactly one day dotted and no way back to the others.
    private func matching(ignoringSelectedDay: Bool) -> [Recording] {
        model.recordings.filter { recording in
            switch filter {
            case .all: break
            case .transcribed: if !recording.isTranscribed { return false }
            case .pending: if recording.isTranscribed { return false }
            }

            if !ignoringSelectedDay, let selectedDay {
                // `isDate(_:inSameDayAs:)` rather than comparing `startOfDay`
                // values: it's calendar-aware, so a day that isn't 24 hours long
                // across a DST change still matches correctly.
                guard Calendar.current.isDate(recording.createdAt, inSameDayAs: selectedDay)
                else { return false }
            }

            if let categoryFilter {
                // Case-insensitive to match `CategoryStore.category(named:)` and
                // `AutoOrganizer`, which stores whatever case the model returned.
                guard let name = recording.categoryName,
                      name.compare(categoryFilter, options: .caseInsensitive) == .orderedSame
                else { return false }
            }

            // AND, not OR. An empty selection matches everything.
            guard RecordingTags.matches(recordingTagIds: recording.tagIds, selected: tagFilter)
            else { return false }

            guard !searchText.isEmpty else { return true }
            let needle = searchText.lowercased()
            if recording.displayTitle.lowercased().contains(needle) { return true }
            return recording.transcript?.plainText.lowercased().contains(needle) ?? false
        }
    }

    /// `RecordingDayGroup` rather than a private type: the timeline and the
    /// calendar's day sections both render these, and two groupings that could
    /// drift apart is exactly the bug the shared `TranscriptBlockRow` exists to
    /// prevent one screen down.
    private var groups: [RecordingDayGroup] {
        let calendar = Calendar.current
        let buckets = Dictionary(grouping: filtered) { calendar.startOfDay(for: $0.createdAt) }
        return buckets.keys.sorted(by: >).map { day in
            RecordingDayGroup(day: day, title: Self.title(for: day), recordings: buckets[day] ?? [])
        }
    }

    private static func title(for day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }
}
