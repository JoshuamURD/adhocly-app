import AdhoclyCore
import SwiftUI

struct ScheduleView: View {
    let model: AppModel
    let store: TaskStore
    let tasks: [TaskItem]
    let editTask: (TaskItem) -> Void
    @AppStorage("schedulePeriod") private var period = SchedulePeriod.week
    @State private var date = Date()
    @Environment(\.calendar) private var calendar
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric private var dayWidth = 156.0
    @ScaledMetric private var monthCellHeight = 244.0
    @ScaledMetric private var compactCellHeight = 60.0

    var body: some View {
        let days = period.days(containing: date, calendar: calendar)
        let entries = Schedule.entries(tasks, days: days, calendar: calendar)
        let byDay = Dictionary(grouping: entries) { calendar.startOfDay(for: $0.date) }
        VStack(spacing: 0) {
            controls(days: days)
            if entries.isEmpty {
                Text("No planned or due tasks in this period.")
                    .font(.callout).foregroundStyle(.secondary)
                    .padding(.bottom, 12)
                    .accessibilityIdentifier("schedule-empty")
            }
            GeometryReader { geometry in
                if period == .month {
                    monthGrid(days: days, entries: byDay,
                              compact: geometry.size.width < 700 || typeSize.isAccessibilitySize)
                } else {
                    timeline(days: days, entries: byDay, width: geometry.size.width)
                }
            }
        }
    }

    private func controls(days: [Date]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Calendar view", selection: $period) {
                ForEach(SchedulePeriod.allCases, id: \.self) { Text($0.name).tag($0) }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("schedule-period")
            HStack(spacing: 8) {
                Button { date = period.moving(date, by: -1, calendar: calendar) } label: {
                    Image(systemName: "chevron.left").frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .accessibilityLabel("Previous \(period.name.lowercased())")
                .accessibilityIdentifier("schedule-previous")
                Button { date = period.moving(date, by: 1, calendar: calendar) } label: {
                    Image(systemName: "chevron.right").frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .accessibilityLabel("Next \(period.name.lowercased())")
                .accessibilityIdentifier("schedule-next")
                Spacer(minLength: 0)
                DatePicker("Schedule date", selection: $date, displayedComponents: .date)
                    .labelsHidden().datePickerStyle(.compact)
                    .accessibilityLabel("Schedule date")
                Button { date = Date() } label: {
                    Text("Today").frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                }
                .accessibilityIdentifier("schedule-today")
            }
            .buttonStyle(.plain)
            ViewThatFits(in: .horizontal) {
                HStack { rangeTitle(days); Spacer(); legend }
                VStack(alignment: .leading, spacing: 8) { rangeTitle(days); legend }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    private func rangeTitle(_ days: [Date]) -> some View {
        let title: String
        if period == .month {
            title = date.formatted(.dateTime.month(.wide).year())
        } else if period == .day {
            title = date.formatted(date: .complete, time: .omitted)
        } else {
            title = "\(days.first!.formatted(date: .abbreviated, time: .omitted)) – \(days.last!.formatted(date: .abbreviated, time: .omitted))"
        }
        return Text(title).font(.headline)
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("schedule-range")
    }

    private var legend: some View {
        HStack(spacing: 12) {
            Label("Planned", systemImage: "calendar").foregroundStyle(Color.accentColor)
            Label("Due", systemImage: "flag").foregroundStyle(Color.orange)
        }
        .font(.caption)
    }

    private func timeline(days: [Date], entries: [Date: [ScheduleEntry]], width: CGFloat) -> some View {
        let columnWidth = max(dayWidth, (width - 60) / CGFloat(days.count))
        let firstHour = min(8, entries.values.flatMap { $0 }.map { calendar.component(.hour, from: $0.date) }.min() ?? 8)
        return ScrollView(.horizontal) {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    Text("Time").font(.caption).foregroundStyle(.secondary).frame(width: 60)
                    ForEach(days, id: \.self) { day in
                        dayHeading(day).frame(width: columnWidth)
                    }
                }
                .padding(.vertical, 8)
                .background(AppStyle.surface)
                Divider()
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(0..<24) { hour in
                                HStack(alignment: .top, spacing: 0) {
                                    Text(String(format: "%02d:00", hour))
                                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                        .frame(width: 60).padding(.top, 10)
                                    ForEach(days, id: \.self) { day in
                                        VStack(spacing: 4) {
                                            ForEach((entries[day] ?? []).filter { calendar.component(.hour, from: $0.date) == hour }) { entry in
                                                entryButton(entry)
                                            }
                                        }
                                        .padding(4)
                                        .frame(width: columnWidth, alignment: .top)
                                        .frame(minHeight: 64, alignment: .top)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .overlay(alignment: .bottom) { Divider() }
                                .id(hour)
                            }
                        }
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .onAppear { proxy.scrollTo(firstHour, anchor: .top) }
                    .onChange(of: days) { _, _ in proxy.scrollTo(firstHour, anchor: .top) }
                }
            }
            .frame(width: 60 + columnWidth * CGFloat(days.count))
        }
    }

    private func dayHeading(_ day: Date) -> some View {
        VStack(spacing: 4) {
            Text(day.formatted(.dateTime.weekday(.abbreviated))).font(.caption).foregroundStyle(.secondary)
            Text(day.formatted(.dateTime.day())).font(.title3.weight(.semibold))
                .foregroundStyle(calendar.isDateInToday(day) ? Color.white : Color.primary)
                .frame(minWidth: 32, minHeight: 32)
                .background(calendar.isDateInToday(day) ? Color.accentColor : Color.clear, in: Circle())
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(day.formatted(date: .complete, time: .omitted))
    }

    private func monthGrid(days: [Date], entries: [Date: [ScheduleEntry]], compact: Bool) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 1) {
                ForEach(Array(days.prefix(7)), id: \.self) { day in
                    Text(day.formatted(.dateTime.weekday(compact ? .narrow : .abbreviated)))
                        .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity).padding(.vertical, 10)
                        .accessibilityLabel(day.formatted(.dateTime.weekday(.wide)))
                }
            }
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 1), count: 7), spacing: 1) {
                    ForEach(days, id: \.self) { day in
                        monthCell(day, entries: entries[day] ?? [], compact: compact)
                    }
                }
                .padding(.bottom, 16)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .padding(.horizontal, compact ? 4 : 20)
    }

    private func monthCell(_ day: Date, entries: [ScheduleEntry], compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Button { openDay(day) } label: {
                VStack(spacing: 4) {
                    Text(day.formatted(.dateTime.day()))
                        .font(.callout.weight(calendar.isDateInToday(day) ? .bold : .regular))
                        .foregroundStyle(calendar.isDateInToday(day) ? Color.accentColor : Color.primary)
                    if compact && !entries.isEmpty {
                        HStack(spacing: 3) {
                            if entries.contains(where: { $0.kind == .planned }) { Circle().fill(Color.accentColor).frame(width: 5, height: 5) }
                            if entries.contains(where: { $0.kind == .due }) { Circle().fill(Color.orange).frame(width: 5, height: 5) }
                        }
                        Text("\(entries.count)").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: compact ? compactCellHeight - 8 : 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(day.formatted(date: .complete, time: .omitted)), \(entries.count) planned or due entries. Show day")
            .accessibilityIdentifier("schedule-day-\(LocalDateTime.string(from: day, calendar: calendar).prefix(10))")
            if !compact {
                ForEach(entries.prefix(2)) { entry in entryButton(entry, compact: true) }
                if entries.count > 2 {
                    Button("+\(entries.count - 2) more") { openDay(day) }
                        .font(.caption).frame(minHeight: 44)
                        .accessibilityLabel("Show all \(entries.count) entries on \(day.formatted(date: .complete, time: .omitted))")
                }
            }
            Spacer(minLength: 0)
        }
        .padding(4)
        .frame(height: compact ? compactCellHeight : monthCellHeight, alignment: .top)
        .frame(maxWidth: .infinity)
        .background(calendar.isDate(day, equalTo: date, toGranularity: .month) ? AppStyle.surface : Color.primary.opacity(0.025))
        .overlay { Rectangle().strokeBorder(AppStyle.border).allowsHitTesting(false) }
    }

    private func entryButton(_ entry: ScheduleEntry, compact: Bool = false) -> some View {
        let color: Color = entry.kind == .planned ? .accentColor : .orange
        return TaskQuickEdit(model: model, store: store, task: entry.task, editDetails: editTask) {
            VStack(alignment: .leading, spacing: 4) {
                Label("\(entry.kind.name) · \(entry.date.formatted(date: .omitted, time: .shortened))", systemImage: entry.kind.symbol)
                    .font(.caption2).foregroundStyle(color)
                    .lineLimit(1)
                Text(entry.task.title).font(compact ? .caption : .callout.weight(.medium))
                    .strikethrough(entry.task.completed)
                    .foregroundStyle(entry.task.completed ? .secondary : .primary)
                    .lineLimit(compact ? 1 : 2)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        }
        .padding(8)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
        .overlay(alignment: .leading) { RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 3) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(entry.task.title), \(entry.kind.name) \(entry.date.formatted(date: .abbreviated, time: .shortened)), \(entry.task.project)\(entry.task.completed ? ", completed" : "")")
        .accessibilityIdentifier("schedule-entry-\(entry.id)")
        .accessibilityAction(named: entry.task.completed ? "Mark incomplete" : "Complete") {
            model.perform { try store.toggle(entry.task.id) }
        }
    }

    private func openDay(_ day: Date) {
        date = day
        period = .day
    }
}
