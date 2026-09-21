import AdhoclyCore
import SwiftUI

struct KanbanView: View {
    let model: AppModel
    let store: TaskStore
    let board: KanbanBoard
    let field: TaskField
    let tasks: [TaskItem]
    let editTask: (TaskItem) -> Void
    let addTask: (TaskItem) -> Void
    @State private var editColumns = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var targetedLane: String?
    @State private var targetedCard: String?
    @State private var cardHeights: [String: CGFloat] = [:]

    private var lanes: [KanbanLane] { Kanban.lanes(field: field, tasks: store.tasks, completeName: store.completeName) }

    var body: some View {
        GeometryReader { geometry in
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 16) {
                    ForEach(lanes) { lane in
                        column(lane, width: min(320, max(240, geometry.size.width - 48)))
                    }
                }
                .scrollTargetLayout()
                .padding(.horizontal, 24)
                .padding(.bottom, 16)
            }
            .scrollTargetBehavior(.viewAligned)
            .scrollDismissesKeyboard(.interactively)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Picker("Sort cards", selection: Binding(get: { board.sortMode }, set: { mode in
                        var updated = board
                        updated.sortMode = mode
                        model.perform { try store.saveBoard(updated, replacing: board) }
                    })) {
                        ForEach(KanbanSort.allCases, id: \.self) { mode in Text(mode.name).tag(mode) }
                    }
                } label: { Label("Sort cards", systemImage: "arrow.up.arrow.down") }
                .accessibilityLabel("Sort cards")
            }
            ToolbarItem(placement: .secondaryAction) {
                Button("Edit \(field.id == "status" ? "statuses" : "property")", systemImage: "slider.horizontal.3") { editColumns = true }
            }
        }
        .sheet(isPresented: $editColumns) { FieldEditorView(model: model, store: store, draft: field, original: field) }
    }

    private func column(_ lane: KanbanLane, width: CGFloat) -> some View {
        let cards = Kanban.sorted(tasks, on: board).filter { Kanban.laneID(task: $0, fieldId: field.id) == lane.id }
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: lane.isComplete ? "checkmark.circle.fill" : "circle.dotted")
                    .foregroundStyle(lane.isComplete ? Color.accentColor : Color.secondary)
                    .font(.subheadline)
                Text(lane.name).font(.headline)
                Text("\(cards.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(AppStyle.surface, in: Capsule())
                Spacer()
                Button {
                    var task = TaskItem()
                    if lane.isComplete { task.statusId = "complete"; task.completed = true }
                    else if field.id == "status" { task.statusId = lane.value! }
                    else { task.properties[field.id] = lane.value }
                    addTask(task)
                } label: { Image(systemName: "plus").frame(width: 44, height: 44) }
                .buttonStyle(.plain)
                .accessibilityLabel("Add task to \(lane.name)")
            }
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(cards) { task in
                        card(task, in: lane, cards: cards)
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { cardHeights[task.id] = $0 }
                            .dropDestination(for: String.self) { ids, location in
                                drop(ids, to: lane, relativeTo: board.sortMode == .manual ? task.id : nil,
                                     after: location.y > (cardHeights[task.id] ?? 0) / 2)
                            } isTargeted: { targeted in
                                if targeted { targetedCard = task.id }
                                else if targetedCard == task.id { targetedCard = nil }
                            }
                    }
                    if cards.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: lane.isComplete ? "checkmark" : "square.dashed")
                                .font(.title2.weight(.light))
                            Text(lane.isComplete ? "Finished work lands here" : "Room for the next step")
                                .font(.callout)
                            Text("Use + to add, or move a card here.").font(.caption)
                        }
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 140)
                        .overlay {
                            RoundedRectangle(cornerRadius: 12)
                                .strokeBorder(AppStyle.border, style: StrokeStyle(lineWidth: 1, dash: [4]))
                        }
                    }
                }
                .padding(2)
                .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: cards.map(\.id))
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .padding(12)
        .frame(width: width)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(targetedLane == lane.id ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.035),
                    in: RoundedRectangle(cornerRadius: 18))
        .contentShape(Rectangle())
        .dropDestination(for: String.self) { ids, _ in
            drop(ids, to: lane)
        } isTargeted: { targeted in
            if targeted { targetedLane = lane.id }
            else if targetedLane == lane.id { targetedLane = nil }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(lane.name), \(cards.count) tasks")
    }

    private func drop(_ ids: [String], to lane: KanbanLane, relativeTo targetId: String? = nil, after: Bool = false) -> Bool {
        guard ids.count == 1, let id = ids.first, store.tasks.contains(where: { $0.id == id }) else { return false }
        targetedLane = nil
        targetedCard = nil
        // Let the native drag finish before relocating its source view.
        Task { @MainActor in
            await Task.yield()
            model.perform { try store.move(id, to: lane, on: board, relativeTo: targetId, after: after) }
        }
        return true
    }

    private func card(_ task: TaskItem, in lane: KanbanLane, cards: [TaskItem]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { editTask(task) } label: {
                VStack(alignment: .leading, spacing: 6) {
                    Text(task.title).font(.body.weight(.medium)).strikethrough(task.completed)
                        .foregroundStyle(task.completed ? .secondary : .primary)
                    Label(task.project, systemImage: "folder").font(.caption).foregroundStyle(.secondary)
                        .padding(.bottom, 4)
                    if !task.details.isEmpty {
                        Text(task.details).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    if let planned = task.plannedFor { TaskDateLabel(value: planned, completed: task.completed) }
                    if let due = task.dueOn { TaskDateLabel(value: due, isDue: true, completed: task.completed) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            HStack {
                Button { model.perform { try store.toggle(task.id) } } label: {
                    Image(systemName: task.completed ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(task.completed ? Color.accentColor : Color.secondary)
                        .frame(minWidth: 44, minHeight: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(task.completed ? "Reopen \(task.title)" : "Complete \(task.title)")
                if field.id != "status" { Text(store.statusName(task.statusId)).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                if store.isPending(task.id) {
                    Image(systemName: "clock.arrow.circlepath").font(.caption)
                        .accessibilityLabel("Pending sync")
                }
                Menu {
                    if board.sortMode == .manual, let index = cards.firstIndex(where: { $0.id == task.id }) {
                        Button("Move up") {
                            model.perform { try store.move(task.id, to: lane, on: board, relativeTo: cards[index - 1].id) }
                        }
                        .disabled(index == 0)
                        Button("Move down") {
                            model.perform { try store.move(task.id, to: lane, on: board, relativeTo: cards[index + 1].id, after: true) }
                        }
                        .disabled(index == cards.count - 1)
                        Divider()
                    }
                    ForEach(lanes.filter { $0.id != Kanban.laneID(task: task, fieldId: field.id) }) { lane in
                        Button("Move to \(lane.name)") { model.perform { try store.move(task.id, to: lane, on: board) } }
                    }
                    Divider()
                    Button("Edit") { editTask(task) }
                    Button("Delete task", role: .destructive) { model.perform { try store.delete(task.id) } }
                } label: { Label("Move", systemImage: "arrow.right").font(.caption).frame(minHeight: 44) }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityLabel("Move or edit \(task.title)")
            }
        }
        .padding(14)
        .background(AppStyle.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(targetedCard == task.id ? Color.accentColor : AppStyle.border, lineWidth: targetedCard == task.id ? 2 : 1)
                .allowsHitTesting(false)
        }
        .help(board.sortMode == .manual ? "Drop on the upper or lower half of a card to place it before or after." : "Choose Manual sorting to reorder cards.")
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Card: \(task.title)")
        .draggable(task.id)
    }
}
