import SwiftUI

// MARK: - Month grid

/// A month of days, marking the ones that have recordings, above the Library
/// list.
///
/// **Dependency-free on purpose.** It takes a `[Date: Int]` and a selection
/// binding — never `[Recording]`, `AppModel`, or `RecordingStore`. Two reasons:
///
/// - A cell body that scanned the library to decide whether to draw its dot
///   would be O(recordings) per cell, i.e. ~31 full walks of the library on
///   every re-render, including every re-render caused by typing in the search
///   field. The caller computes the counts **once** (`CalendarGrid.countsByDay`)
///   and hands them over already bucketed.
/// - Keeping the model out means this can be dropped anywhere a day histogram
///   exists, and it can be reasoned about without knowing anything about sync.
///
/// **The card is inside this view.** `ContentCard` is applied here rather than
/// left to the caller, because a grid is content and `CLAUDE.md` is explicit
/// that content never sits on glass — building the card in makes that
/// unviolatable by an integrator. The caller supplies only the surrounding
/// horizontal padding.
///
/// Everything about weeks, months and day arithmetic goes through
/// `Calendar.current`, so week start, month names, weekday order and numerals
/// all follow the system locale. Nothing here assumes Sunday-first or English.
struct CalendarGrid: View {

    /// Recording count per day, keyed by `Calendar.current.startOfDay(for:)`.
    ///
    /// **Keys must be produced by `startOfDay`** — `Date` equality is exact, so a
    /// key built from a raw `createdAt` never matches a lookup and the day
    /// silently loses its dot. That's the whole reason `countsByDay(for:)`
    /// exists rather than leaving the bucketing to each caller.
    ///
    /// It may cover any range; only the visible month is ever read, and the
    /// lookups are ~31 dictionary hits.
    let countsByDay: [Date: Int]

    /// The filtered day, or nil for "no day filter". Tapping a day sets it;
    /// tapping the already-selected day clears it back to nil.
    @Binding var selectedDay: Date?

    /// First instant of the month on screen. Paging moves it by whole months
    /// via `Calendar`, never by seconds — see `page(by:)`.
    @State private var visibleMonth: Date

    /// Width of the grid, measured once, so a cell can be clamped to its column
    /// at large Dynamic Type sizes instead of overflowing it. Same
    /// `onGeometryChange` idiom `WaveformView` uses.
    @State private var gridWidth: CGFloat = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Nominal cell side at the default text size. Scaled, because the day
    /// number inside it is, and a fixed 36pt box clips a body-size numeral at
    /// the accessibility sizes.
    @ScaledMetric private var cellSide: CGFloat = 36
    /// The "has recordings" dot. Scaled with the rest so it doesn't shrink into
    /// invisibility relative to a large numeral.
    @ScaledMetric private var dotSide: CGFloat = 5

    private static let columnSpacing: CGFloat = 2
    private static let rowSpacing: CGFloat = 4

    init(countsByDay: [Date: Int], selectedDay: Binding<Date?>) {
        self.countsByDay = countsByDay
        self._selectedDay = selectedDay
        // Open on the selected day's month when there is one, so a selection
        // restored from elsewhere isn't off-screen. `@State`'s initial value is
        // only used on first construction, which is why `.onChange(of:)` below
        // handles later out-of-month selections rather than this line.
        _visibleMonth = State(
            initialValue: Self.monthStart(of: selectedDay.wrappedValue ?? Date()))
    }

    var body: some View {
        ContentCard {
            VStack(spacing: Metrics.compactSpacing) {
                header
                weekdayHeader
                grid
            }
        }
        // The card's height changes with the month's row count (a February that
        // starts on the first weekday needs four rows; a 31-day month starting
        // on the last needs six), so the change is animated rather than
        // snapping the list below it.
        // `Animation.snappy` spelled out rather than as `.snappy`: the other arm
        // of the ternary is `nil`, so there is no contextual base for implicit
        // member lookup to resolve against.
        .animation(reduceMotion ? nil : Animation.snappy(duration: 0.25), value: visibleMonth)
        .onChange(of: selectedDay) { _, day in
            guard let day, !calendar.isDate(day, equalTo: visibleMonth, toGranularity: .month)
            else { return }
            visibleMonth = Self.monthStart(of: day)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 0) {
            Text(monthTitle)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

            Spacer(minLength: Metrics.compactSpacing)

            pageButton(
                by: -1,
                symbol: "chevron.left",
                label: "Previous month",
                // The destination month, so VoiceOver says where the button
                // goes rather than just that it moves.
                value: Self.title(of: month(offsetBy: -1)))
            pageButton(
                by: 1,
                symbol: "chevron.right",
                label: "Next month",
                value: Self.title(of: month(offsetBy: 1)))
        }
    }

    /// Plain, not glass: this sits inside a `ContentCard`, and glass belongs to
    /// the navigation layer above content, never inside it.
    private func pageButton(
        by months: Int, symbol: String, label: String, value: String
    ) -> some View {
        Button {
            page(by: months)
        } label: {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                // 44 × 36 plus `contentShape` rather than the icon's own
                // bounds, which would be a ~14pt target.
                .frame(width: 44, height: 36)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(months > 0 && !canPageForward)
        .foregroundStyle(months > 0 && !canPageForward ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.tint))
        .accessibilityLabel(label)
        .accessibilityValue(value)
    }

    /// Weekday initials, rotated to the locale's first weekday.
    ///
    /// `shortWeekdaySymbols` is always Sunday-first (index 0 = weekday 1)
    /// regardless of locale, while `firstWeekday` is 1…7 — so the rotation is
    /// required even though both come from the same `Calendar`.
    private var weekdayHeader: some View {
        HStack(spacing: Self.columnSpacing) {
            ForEach(weekdaySymbols, id: \.self) { symbol in
                Text(symbol)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
        // The row is decorative: every day cell already names its own weekday
        // through the formatted date in its label, so reading seven initials
        // first is noise.
        .accessibilityHidden(true)
    }

    private var weekdaySymbols: [String] {
        let symbols = calendar.shortWeekdaySymbols
        let first = calendar.firstWeekday - 1
        return (0..<symbols.count).map { symbols[($0 + first) % symbols.count] }
    }

    // MARK: Grid

    private var grid: some View {
        LazyVGrid(
            columns: Array(
                repeating: GridItem(.flexible(), spacing: Self.columnSpacing),
                count: 7),
            spacing: Self.rowSpacing
        ) {
            ForEach(slots) { slot in
                if let day = slot.day {
                    DayCell(
                        day: day,
                        count: countsByDay[day] ?? 0,
                        isSelected: selectedDay.map { calendar.isDate($0, inSameDayAs: day) } ?? false,
                        isToday: calendar.isDateInToday(day),
                        side: resolvedCellSide,
                        dotSide: dotSide,
                        action: { toggle(day) })
                } else {
                    // A leading or trailing blank. `Color.clear` rather than
                    // `EmptyView` so the column keeps its width and the weekday
                    // alignment survives.
                    Color.clear
                        .frame(height: resolvedCellSide)
                        .accessibilityHidden(true)
                }
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { gridWidth = $0 }
    }

    /// The cell side, clamped to its column. At the largest accessibility text
    /// sizes the scaled side exceeds a seventh of a phone's width, and an
    /// unclamped circle would overlap its neighbours.
    private var resolvedCellSide: CGFloat {
        guard gridWidth > 0 else { return cellSide }
        let column = gridWidth / 7 - Self.columnSpacing
        return max(24, min(cellSide, column))
    }

    /// One grid position: a day, or a blank that pads the month into alignment.
    private struct Slot: Identifiable {
        /// Position in the grid. Stable within a month, which is all `ForEach`
        /// needs — the whole array is rebuilt when the month changes.
        let id: Int
        let day: Date?
    }

    /// The visible month as 7-column rows, with leading blanks so the 1st lands
    /// under its weekday and trailing blanks so the last row is complete.
    ///
    /// Days are produced with `Calendar.date(byAdding: .day)` and re-normalised
    /// through `startOfDay`, **never** by adding 86,400 seconds. Two hazards:
    /// a DST transition makes a day 23 or 25 hours long, so second-arithmetic
    /// drifts a day per transition; and in the zones whose transition falls *at
    /// midnight* (Chile, and Brazil historically) midnight itself may not exist
    /// that day, so even `byAdding: .day` lands at 01:00 — which would never
    /// match a `startOfDay` key in `countsByDay`.
    private var slots: [Slot] {
        let monthStart = Self.monthStart(of: visibleMonth)
        guard let dayCount = calendar.range(of: .day, in: .month, for: monthStart)?.count
        else { return [] }

        // 0…6 from the locale's first weekday. `+ 7` before the modulo because
        // `weekday - firstWeekday` is negative whenever the month starts before
        // the week does (e.g. a Sunday start in a Monday-first locale).
        let weekday = calendar.component(.weekday, from: monthStart)
        let leading = (weekday - calendar.firstWeekday + 7) % 7

        var slots = (0..<leading).map { Slot(id: $0, day: nil) }
        for offset in 0..<dayCount {
            let day = calendar.date(byAdding: .day, value: offset, to: monthStart)
            // A nil day is unreachable, and mapping it to a blank slot rather
            // than skipping it keeps the rest of the month under the right
            // weekdays instead of shifting it a column left.
            slots.append(Slot(id: leading + offset, day: day.map { calendar.startOfDay(for: $0) }))
        }
        // Complete the final row. Only the last row is padded — always drawing
        // six rows would leave up to two empty rows of dead space in a short
        // month, which reads worse than the card changing height.
        let remainder = slots.count % 7
        if remainder != 0 {
            let base = slots.count
            for index in 0..<(7 - remainder) {
                slots.append(Slot(id: base + index, day: nil))
            }
        }
        return slots
    }

    // MARK: Selection and paging

    /// Tapping the selected day clears the filter — the grid is the only place
    /// the day filter can be cleared from, so a second tap has to do it.
    private func toggle(_ day: Date) {
        if let selectedDay, calendar.isDate(selectedDay, inSameDayAs: day) {
            self.selectedDay = nil
        } else {
            selectedDay = day
        }
    }

    private func page(by months: Int) {
        guard months < 0 || canPageForward else { return }
        visibleMonth = month(offsetBy: months)
    }

    private func month(offsetBy months: Int) -> Date {
        let base = Self.monthStart(of: visibleMonth)
        return calendar.date(byAdding: .month, value: months, to: base) ?? base
    }

    /// Forward paging stops at the current month: a recording can't be created
    /// in the future, so every later month is guaranteed empty and paging into
    /// them is a dead end that looks like the grid has lost its data.
    ///
    /// Backward paging is deliberately **unbounded** — bounding it would mean
    /// knowing the oldest recording, which is exactly the library dependency
    /// this view avoids, and the cost of an empty past month is one tap back.
    private var canPageForward: Bool {
        Self.monthStart(of: visibleMonth) < Self.monthStart(of: Date())
    }

    // MARK: Formatting

    private var calendar: Calendar { Calendar.current }

    private var monthTitle: String { Self.title(of: visibleMonth) }

    private static func title(of month: Date) -> String {
        month.formatted(.dateTime.month(.wide).year())
    }

    private static func monthStart(of date: Date) -> Date {
        let calendar = Calendar.current
        // `dateInterval(of: .month)` rather than rebuilding from
        // `dateComponents([.year, .month])`: it resolves the month's real first
        // instant in this calendar and time zone, including the non-Gregorian
        // calendars the locale may be using.
        return calendar.dateInterval(of: .month, for: date)?.start
            ?? calendar.startOfDay(for: date)
    }

    // MARK: Counting

    /// Recordings per day, bucketed by `startOfDay`, ready for `countsByDay`.
    ///
    /// Lives here rather than at the call site so the key convention the grid
    /// looks up by is defined in the same file as the lookup — a caller
    /// bucketing by anything else gets a grid with no dots and no error.
    static func countsByDay(for dates: [Date]) -> [Date: Int] {
        let calendar = Calendar.current
        var counts: [Date: Int] = [:]
        for date in dates {
            counts[calendar.startOfDay(for: date), default: 0] += 1
        }
        return counts
    }
}

// MARK: - Day cell

/// One day. A `Button` even when the day has no recordings: selecting an empty
/// day is how the caller's "nothing on this day" empty state is reached, and an
/// inert cell would make that state unreachable. "Inert" here is visual — no
/// dot, no ring, no fill — not untappable.
private struct DayCell: View {

    let day: Date
    let count: Int
    let isSelected: Bool
    let isToday: Bool
    /// Resolved by the parent so each cell doesn't re-read `@ScaledMetric` from
    /// the environment, and so all 42 agree on one size.
    let side: CGFloat
    let dotSide: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                // **Today and selected are different states and can coexist**,
                // so they use different marks rather than competing for one:
                // selection is a filled disc inset inside the cell, today is a
                // ring at the cell's edge. Both together read as a ringed disc.
                if isSelected {
                    Circle()
                        .fill(.tint)
                        .padding(2.5)
                }
                if isToday {
                    Circle()
                        // Dimmed over a selected fill so the ring reads as an
                        // outline rather than fighting the disc for attention.
                        .strokeBorder(.tint.opacity(isSelected ? 0.5 : 1), lineWidth: 1.5)
                }

                VStack(spacing: 3) {
                    // Formatted rather than `String(component:)` so locales with
                    // their own numerals get them.
                    Text(day.formatted(.dateTime.day()))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(numberStyle)
                    // A single dot, not a count badge: at cell size the badge is
                    // unreadable once Dynamic Type is turned up, and the exact
                    // count is in the accessibility label and one tap away in
                    // the list. `opacity` rather than a conditional so every
                    // cell has the same intrinsic height and the numerals stay
                    // on one baseline across the row.
                    Circle()
                        .fill(dotStyle)
                        .frame(width: dotSide, height: dotSide)
                        .opacity(count > 0 ? 1 : 0)
                }
            }
            .frame(width: side, height: side)
            // The tap target is the whole column, not just the disc — a 36pt
            // circle is under the 44pt minimum, and the gaps between cells are
            // dead space otherwise.
            .frame(maxWidth: .infinity)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityHint(isSelected ? "Clears the day filter." : "Filters the library to this day.")
    }

    /// `.background` resolves to white in light mode and black in dark, which
    /// keeps contrast against both variants of `Color.bounce`. A literal
    /// `.white` is unreadable on the light-blue dark-mode tint.
    private var numberStyle: AnyShapeStyle {
        if isSelected { return AnyShapeStyle(.background) }
        if isToday { return AnyShapeStyle(.tint) }
        return AnyShapeStyle(.primary)
    }

    private var dotStyle: AnyShapeStyle {
        isSelected ? AnyShapeStyle(.background) : AnyShapeStyle(.tint)
    }

    /// Spelled out, because "14" alone locates nothing when swiping through a
    /// grid, and the count is the information the grid exists to convey.
    private var accessibilityLabel: String {
        let date = day.formatted(.dateTime.day().month(.wide))
        switch count {
        case 0: return "\(date), no recordings"
        case 1: return "\(date), 1 recording"
        default: return "\(date), \(count) recordings"
        }
    }
}
