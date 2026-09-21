import AdhoclyCore
import SwiftUI

private struct EditorRequest: Identifiable {
    var id: String { draft.id }
    let draft: TaskItem
    let original: TaskItem?
}

private struct BoardRequest: Identifiable {
    var id: String { draft.id }
    let draft: KanbanBoard
    let original: KanbanBoard?
}

private struct FolderRequest: Identifiable {
    var id: String { draft.id }
    let draft: ProjectFolder
    let original: ProjectFolder?
}

struct TaskListView: View {
    let model: AppModel
    let store: TaskStore
    @State private var selection: String? = "active"
    @State private var projectPath: [String] = []
    @State private var taskFilter = "active"
    @State private var search = ""
    @State private var today = Date()
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("todaySort") private var todaySort = TodayTaskOrder.due
    @AppStorage("todayGrouping") private var todayGrouping = ""
    @State private var editor: EditorRequest?
    @State private var editingTitle = false
    @State private var showConnection = false
    @State private var showReview = false
    @State private var showProperties = false
    @State private var showNewProject = false
    @State private var folderEditor: FolderRequest?
    @State private var deletingProject: Project?
    @State private var boardEditor: BoardRequest?
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    private func board(for scope: String) -> KanbanBoard? {
        guard scope.hasPrefix("board:") else { return nil }
        return store.boards.first { $0.id == String(scope.dropFirst(6)) }
    }

    private func tasks(for scope: String) -> [TaskItem] {
        let scopedTasks = scope == "today" ? TodayTasks.matching(store.tasks, now: today) : store.tasks
        return scopedTasks.filter { task in
            let matches: Bool
            switch scope {
            case "active": matches = !task.completed
            case "completed": matches = task.completed
            case let value where value.hasPrefix("project:"):
                matches = task.projectId == String(value.dropFirst(8))
            default: matches = true
            }
            return matches && (search.isEmpty || task.title.localizedCaseInsensitiveContains(search)
                               || task.project.localizedCaseInsensitiveContains(search)
                               || task.details.localizedCaseInsensitiveContains(search))
        }
    }

    private func title(for scope: String) -> String {
        if let board = board(for: scope) { return board.name }
        if scope.hasPrefix("project:") {
            return store.projects.first { $0.id == String(scope.dropFirst(8)) }?.name ?? "Project"
        }
        if scope == "schedule" { return "Schedule" }
        return scope == "today" ? "Today" : scope == "completed" ? "Completed" : scope == "all" ? "All tasks" : "To do"
    }

    private func newTask(in scope: String) -> TaskItem {
        if scope.hasPrefix("project:"),
           let project = store.projects.first(where: { $0.id == String(scope.dropFirst(8)) }) {
            return TaskItem(projectId: project.id, project: project.name)
        }
        return TaskItem()
    }

    var body: some View {
        Group {
            #if os(iOS)
            if sizeClass == .compact { phoneNavigation }
            else { splitNavigation }
            #else
            splitNavigation
            #endif
        }
        .tint(.accentColor)
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in today = Date() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { today = Date() }
        }
        .sheet(item: $editor) { request in
            TaskEditorView(model: model, store: store, draft: request.draft, original: request.original)
        }
        .sheet(isPresented: $showConnection) { ConnectionView(model: model, store: store) }
        .sheet(isPresented: $showReview) { SyncReviewView(model: model, store: store) }
        .sheet(isPresented: $showProperties) { PropertiesView(model: model, store: store) }
        .sheet(isPresented: $showNewProject) {
            ProjectEditorView { name in
                try store.createProject(named: name)
                model.didSave()
            }
        }
        .sheet(item: $folderEditor) { request in
            FolderEditorView(model: model, store: store, draft: request.draft, original: request.original)
        }
        .confirmationDialog("Delete project?", isPresented: Binding(
            get: { deletingProject != nil }, set: { if !$0 { deletingProject = nil } }
        ), titleVisibility: .visible) {
            if let project = deletingProject {
                Button("Delete “\(project.name)”", role: .destructive) {
                    model.perform { try store.deleteProject(project.id) }
                    deletingProject = nil
                }
            }
        } message: {
            Text("Its tasks will be kept and moved to Inbox.")
        }
        .onChange(of: store.projects) { _, projects in
            if projectPath.contains(where: { scope in !projects.contains { "project:\($0.id)" == scope } }) {
                projectPath.removeAll()
            }
            if let selection, selection.hasPrefix("project:"),
               !projects.contains(where: { "project:\($0.id)" == selection }) {
                self.selection = "project:inbox"
            }
        }
        .sheet(item: $boardEditor) { request in
            BoardEditorView(model: model, store: store, draft: request.draft, original: request.original)
        }
    }

    private var splitNavigation: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("Workspace") {
                    sidebarLink("Today", symbol: "sun.max", scope: "today", count: TodayTasks.matching(store.tasks, now: today).count)
                    NavigationLink(value: "schedule") { Label("Schedule", systemImage: "calendar") }
                        .tag("schedule")
                    sidebarLink("To do", symbol: "checklist", scope: "active", count: store.tasks.filter { !$0.completed }.count)
                    sidebarLink("All tasks", symbol: "tray.full", scope: "all", count: store.tasks.count)
                    sidebarLink("Completed", symbol: "checkmark.circle", scope: "completed", count: store.tasks.filter(\.completed).count)
                }
                Section("Boards") {
                    boardLinks
                    Button("New board", systemImage: "plus") { createBoard() }
                        .foregroundStyle(.secondary)
                }
                Section("Projects") {
                    projectLinks
                    Button("New project", systemImage: "plus") { showNewProject = true }
                    newFolderButton
                }
            }
            .listStyle(.sidebar)
            .navigationTitle("Adhocly")
            .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 300)
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 12) {
                    Label("A little space for what’s next.", systemImage: "leaf")
                        .font(.caption).foregroundStyle(.secondary)
                    Button { showConnection = true } label: {
                        Label("Settings & sync", systemImage: "gearshape")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Settings")
                }
                .padding(20)
            }
        } detail: {
            workspace(selection ?? "active")
        }
        .navigationSplitViewStyle(.balanced)
    }

    #if os(iOS)
    private var phoneNavigation: some View {
        TabView {
            NavigationStack {
                workspace(taskFilter, showFilter: true)
            }
            .tabItem { Label("Tasks", systemImage: "checklist") }
            NavigationStack {
                workspace("schedule")
            }
            .tabItem { Label("Schedule", systemImage: "calendar") }
            NavigationStack {
                directory(isBoards: true)
                    .navigationDestination(for: String.self) { workspace($0) }
            }
            .tabItem { Label("Boards", systemImage: "rectangle.split.3x1") }
            NavigationStack(path: $projectPath) {
                directory(isBoards: false)
                    .navigationDestination(for: String.self) { workspace($0) }
            }
            .tabItem { Label("Projects", systemImage: "folder") }
        }
    }
    #endif

    private func sidebarLink(_ title: String, symbol: String, scope: String, count: Int) -> some View {
        NavigationLink(value: scope) {
            Label {
                HStack {
                    Text(title)
                    Spacer()
                    Text("\(count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            } icon: { Image(systemName: symbol) }
        }
        .tag(scope)
    }

    private var boardLinks: some View {
        ForEach(store.boards) { board in
            NavigationLink(value: "board:\(board.id)") {
                Label(board.name, systemImage: "rectangle.split.3x1")
            }
            .tag("board:\(board.id)")
            .contextMenu { boardActions(board) }
        }
    }

    private var projectLinks: some View {
        ProjectTreeView(model: model, store: store, parentId: nil,
                        editFolder: { folderEditor = FolderRequest(draft: $0, original: $1) },
                        deleteProject: { deletingProject = $0 })
    }

    private var newFolderButton: some View {
        Button("New folder", systemImage: "folder.badge.plus") {
            folderEditor = FolderRequest(draft: ProjectFolder(), original: nil)
        }
    }

    private func directory(isBoards: Bool) -> some View {
        VStack(spacing: 0) {
            WorkspaceHeading(title: isBoards ? "Your boards" : "Your projects",
                             subtitle: isBoards ? "See the work. Find the next step." : "Everything has a place.")
            List {
                if isBoards {
                    ForEach(store.boards) { board in
                        NavigationLink(value: "board:\(board.id)") {
                            directoryRow(board.name, subtitle: "Grouped by \(store.taskFields.first { $0.id == board.fieldId }?.name ?? "property")",
                                         symbol: "rectangle.split.3x1")
                        }
                        .contextMenu { boardActions(board) }
                        .listRowBackground(AppStyle.surface)
                    }
                    Button("New board", systemImage: "plus") { createBoard() }
                        .frame(minHeight: 44)
                        .listRowBackground(AppStyle.surface)
                } else {
                    projectLinks
                    Button("New project", systemImage: "plus") { showNewProject = true }
                        .frame(minHeight: 44)
                        .listRowBackground(AppStyle.surface)
                    newFolderButton
                        .frame(minHeight: 44)
                        .listRowBackground(AppStyle.surface)
                }
            }
            .scrollContentBackground(.hidden)
        }
        .background(AppStyle.canvas)
        .navigationTitle(isBoards ? "Boards" : "Projects")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) { settingsButton }
        }
    }

    private func directoryRow(_ title: String, subtitle: String, symbol: String) -> some View {
        HStack(spacing: 14) {
            WorkspaceIcon(symbol: symbol)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 8)
    }

    private func workspace(_ scope: String, showFilter: Bool = false) -> some View {
        let visibleTasks = tasks(for: scope)
        let selectedBoard = board(for: scope)
        return VStack(spacing: 0) {
            if scope != "schedule" {
                WorkspaceHeading(title: title(for: scope), subtitle: subtitle(for: scope, count: visibleTasks.count))
            }
            if showFilter {
                Picker("Show tasks", selection: $taskFilter) {
                    Text("To do").tag("active")
                    Text("Today").tag("today")
                    Text("All").tag("all")
                    Text("Completed").tag("completed")
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 24)
                .padding(.bottom, 12)
            }
            if scope == "today" { todayControls }
            if scope == "schedule" {
                ScheduleView(model: model, store: store, tasks: visibleTasks,
                             editTask: { editor = EditorRequest(draft: $0, original: $0) })
            } else if let selectedBoard, let field = store.taskFields.first(where: { $0.id == selectedBoard.fieldId }) {
                KanbanView(model: model, store: store, board: selectedBoard, field: field, tasks: visibleTasks,
                           editTask: { editor = EditorRequest(draft: $0, original: $0) },
                           addTask: { editor = EditorRequest(draft: $0, original: nil) })
            } else {
                taskList(visibleTasks, scope: scope)
            }
        }
        .background(AppStyle.canvas)
        .onPreferenceChange(TaskTitleEditingKey.self) { editingTitle = $0 }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !editingTitle { captureBar(scope: scope) }
        }
        .navigationTitle(title(for: scope))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .searchable(text: $search, prompt: "Search tasks")
        .refreshable { await model.sync() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { editor = EditorRequest(draft: newTask(in: scope), original: nil) } label: {
                    Label("New task", systemImage: "plus")
                }
                .keyboardShortcut("n")
                .accessibilityIdentifier("new-task")
                .help("New task (⌘N)")
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("New project", systemImage: "folder.badge.plus") { showNewProject = true }
                    newFolderButton
                    Button("New board", systemImage: "rectangle.split.3x1") { createBoard() }
                    Button("Task properties", systemImage: "tag") { showProperties = true }
                    if let selectedBoard { boardActions(selectedBoard) }
                    if let project = store.projects.first(where: { "project:\($0.id)" == scope }) {
                        ProjectActions(model: model, store: store, project: project,
                                       deleteProject: { deletingProject = $0 })
                    }
                    Divider()
                    Button("Sync now", systemImage: "arrow.triangle.2.circlepath") { Task { await model.sync() } }
                        .disabled(store.isSyncing || store.serverURL.isEmpty)
                    Button("Settings", systemImage: "gearshape") { showConnection = true }
                } label: { Label("More actions", systemImage: "ellipsis.circle") }
                .accessibilityLabel("More actions")
            }
        }
    }

    private func subtitle(for scope: String, count: Int) -> String {
        if !search.isEmpty { return "\(count) matching \(count == 1 ? "task" : "tasks")" }
        if board(for: scope) != nil { return "Move work forward, one card at a time." }
        if scope == "completed" { return "A record of what you’ve taken care of." }
        if scope == "today" { return "\(count) \(count == 1 ? "task" : "tasks") planned or due today." }
        return count == 0 ? "Make room for your next idea." : "\(count) \(count == 1 ? "task" : "tasks") · One thing at a time."
    }

    private var settingsButton: some View {
        Button { showConnection = true } label: { Label("Settings", systemImage: "gearshape") }
    }

    private func createBoard() { boardEditor = BoardRequest(draft: KanbanBoard(), original: nil) }

    @ViewBuilder private func boardActions(_ board: KanbanBoard) -> some View {
        Button("Edit board", systemImage: "slider.horizontal.3") { boardEditor = BoardRequest(draft: board, original: board) }
        Button("Delete board (keeps tasks)", systemImage: "trash", role: .destructive) {
            model.perform { try store.deleteBoard(board.id) }
            if selection == "board:\(board.id)" { selection = "active" }
        }
    }

    private var todayControls: some View {
        ViewThatFits(in: .horizontal) {
            HStack { todaySortMenu; todayGroupMenu; Spacer() }
            VStack(alignment: .leading) { todaySortMenu; todayGroupMenu }
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.subheadline)
        .padding(.horizontal, 24)
        .padding(.bottom, 12)
    }

    private var todaySortMenu: some View {
        Menu {
            Picker("Sort by", selection: $todaySort) {
                ForEach(TodayTaskOrder.allCases, id: \.self) { Text($0.name).tag($0) }
            }
        } label: {
            Label("Sort: \(todaySort.name)", systemImage: "arrow.up.arrow.down")
        }
        .accessibilityIdentifier("today-sort")
    }

    private var todayGroupMenu: some View {
        Menu {
            Picker("Group by", selection: $todayGrouping) {
                Text("None").tag("")
                ForEach(TodayTaskOrder.allCases, id: \.self) { Text($0.name).tag($0.rawValue) }
            }
        } label: {
            Label("Group: \(TodayTaskOrder(rawValue: todayGrouping)?.name ?? "None")", systemImage: "rectangle.3.group")
        }
        .accessibilityIdentifier("today-group")
    }

    private func taskRows(_ tasks: [TaskItem]) -> some View {
        ForEach(tasks) { task in
            taskRow(task)
                .listRowBackground(AppStyle.surface)
                .listRowSeparatorTint(AppStyle.border)
                .swipeActions {
                    Button("Delete", role: .destructive) { model.perform { try store.delete(task.id) } }
                    Button("Edit") { editor = EditorRequest(draft: task, original: task) }
                }
        }
    }

    private func taskList(_ tasks: [TaskItem], scope: String) -> some View {
        List {
            if scope == "today", let grouping = TodayTaskOrder(rawValue: todayGrouping) {
                ForEach(TodayTasks.groups(tasks, by: grouping, sort: todaySort, statuses: store.statusField.options)) { group in
                    Section {
                        taskRows(group.tasks)
                    } header: {
                        HStack {
                            Text(group.name)
                            Spacer()
                            Text("\(group.tasks.count)").monospacedDigit()
                        }
                    }
                }
            } else {
                taskRows(scope == "today" ? TodayTasks.sorted(tasks, by: todaySort, statuses: store.statusField.options) : tasks)
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .overlay {
            if tasks.isEmpty {
                ContentUnavailableView {
                    Label(search.isEmpty ? (scope == "today" ? "Nothing planned or due today" : scope == "completed" ? "Good things take a first step" : "A little room to think") : "No matching tasks",
                          systemImage: search.isEmpty ? "leaf" : "magnifyingglass")
                        .foregroundStyle(Color.accentColor)
                } description: {
                    Text(search.isEmpty ? (scope == "today" ? "Tasks with a planned or due date today will appear here. Use @today or !today in quick capture." : scope == "completed" ? "Completed tasks will appear here." : "Capture an idea below, or add a task with more detail.") : "Try another title, detail, or project name.")
                } actions: {
                    if search.isEmpty && scope != "completed" {
                        Button("Create a task") { editor = EditorRequest(draft: newTask(in: scope), original: nil) }
                            .buttonStyle(.borderedProminent)
                    } else if !search.isEmpty {
                        Button("Clear search") { search = "" }
                    }
                }
            }
        }
    }

    private func taskRow(_ task: TaskItem) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Button { model.perform { try store.toggle(task.id) } } label: {
                Image(systemName: task.completed ? "checkmark.circle.fill" : "circle")
                    .font(.title2.weight(.light))
                    .foregroundStyle(task.completed ? Color.accentColor : Color.secondary)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(task.completed ? "Mark \(task.title) incomplete" : "Complete \(task.title)")
            TaskQuickEdit(model: model, store: store, task: task,
                          editDetails: { editor = EditorRequest(draft: $0, original: $0) }) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(task.title).font(.body.weight(.medium))
                        .strikethrough(task.completed)
                        .foregroundStyle(task.completed ? .secondary : .primary)
                    Text("\(task.project) · \(store.statusName(task.statusId))")
                        .font(.caption).foregroundStyle(.secondary)
                    if !task.details.isEmpty {
                        Text(task.details).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    if let planned = task.plannedFor { TaskDateLabel(value: planned, completed: task.completed) }
                    if let due = task.dueOn { TaskDateLabel(value: due, isDue: true, completed: task.completed) }
                    if task.repeatWeekday != nil {
                        Label("Repeats weekly", systemImage: "repeat").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            if store.isPending(task.id) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.caption).foregroundStyle(.secondary).padding(.top, 16)
                    .accessibilityLabel("Saved locally, pending sync")
                    .help("Saved locally, pending sync")
            }
        }
        .padding(.vertical, 4)
    }

    private func captureBar(scope: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            syncStatus
            if let message = model.reminders.message {
                HStack {
                    Text(message).font(.caption).foregroundStyle(.orange)
                    if model.reminders.needsPermission {
                        Button("Enable alerts") { Task { await model.reminders.enable() } }
                            .font(.caption)
                    }
                }
            }
            CaptureBar(model: model, store: store, projectId: newTask(in: scope).projectId)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(AppStyle.canvas)
        .overlay(alignment: .top) { Divider() }
    }

    @ViewBuilder private var syncStatus: some View {
        if store.issue != nil {
            Button { showReview = true } label: {
                Label("Sync needs your review. Your changes are safe here.", systemImage: "exclamationmark.arrow.triangle.2.circlepath")
            }
            .font(.caption).tint(.orange)
        } else if let error = model.credentialError ?? store.syncError {
            Button { showConnection = true } label: {
                Label(error, systemImage: "wifi.exclamationmark").multilineTextAlignment(.leading)
            }
            .font(.caption).tint(.orange)
        } else if store.serverURL.isEmpty {
            HStack {
                Label("Saved on this device", systemImage: "internaldrive")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Set up sync") { showConnection = true }
            }
            .font(.caption)
        } else if store.isSyncing || store.pendingCount > 0 {
            Label(store.isSyncing ? "Syncing…" : "\(store.pendingCount) changes waiting to sync", systemImage: "arrow.triangle.2.circlepath")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct ProjectActions: View {
    let model: AppModel
    let store: TaskStore
    let project: Project
    let deleteProject: (Project) -> Void

    var body: some View {
        if project.id != "inbox" {
            Menu("Move to folder", systemImage: "folder") {
                Button("Top level") { model.perform { try store.moveProject(project.id, to: nil) } }
                    .disabled(project.folderId == nil)
                ForEach(store.folders) { folder in
                    Button(store.folderPath(folder.id)) {
                        model.perform { try store.moveProject(project.id, to: folder.id) }
                    }
                    .disabled(project.folderId == folder.id)
                }
            }
            Button("Delete project", systemImage: "trash", role: .destructive) { deleteProject(project) }
        }
    }
}

private struct ProjectTreeView: View {
    let model: AppModel
    let store: TaskStore
    let parentId: String?
    let editFolder: (ProjectFolder, ProjectFolder?) -> Void
    let deleteProject: (Project) -> Void

    var body: some View {
        ForEach(store.folders.filter { $0.parentId == parentId }) { folder in
            ProjectFolderRow(model: model, store: store, folder: folder,
                             editFolder: editFolder, deleteProject: deleteProject)
        }
        ForEach(store.projects.filter { $0.folderId == parentId }) { project in
            NavigationLink(value: "project:\(project.id)") {
                Label {
                    HStack {
                        Text(project.name)
                        Spacer()
                        Text("\(store.tasks.filter { $0.projectId == project.id && !$0.completed }.count)")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                } icon: { Image(systemName: project.id == "inbox" ? "tray" : "checklist") }
            }
            .tag("project:\(project.id)")
            .contextMenu {
                ProjectActions(model: model, store: store, project: project, deleteProject: deleteProject)
            }
            .swipeActions {
                if project.id != "inbox" {
                    Button("Delete", role: .destructive) { deleteProject(project) }
                }
            }
        }
    }
}

private struct ProjectFolderRow: View {
    let model: AppModel
    let store: TaskStore
    let folder: ProjectFolder
    let editFolder: (ProjectFolder, ProjectFolder?) -> Void
    let deleteProject: (Project) -> Void
    @AppStorage private var isExpanded: Bool

    init(model: AppModel, store: TaskStore, folder: ProjectFolder,
         editFolder: @escaping (ProjectFolder, ProjectFolder?) -> Void,
         deleteProject: @escaping (Project) -> Void) {
        self.model = model; self.store = store; self.folder = folder
        self.editFolder = editFolder; self.deleteProject = deleteProject
        _isExpanded = AppStorage(wrappedValue: true, "projectFolderExpanded.\(store.serverURL).\(folder.id)")
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            ProjectTreeView(model: model, store: store, parentId: folder.id,
                            editFolder: editFolder, deleteProject: deleteProject)
        } label: {
            Label(folder.name, systemImage: isExpanded ? "folder.fill" : "folder")
        }
        .accessibilityIdentifier("project-folder-\(folder.id)")
        .contextMenu {
            Button("New subfolder", systemImage: "folder.badge.plus") {
                editFolder(ProjectFolder(parentId: folder.id), nil)
            }
            Button("Edit folder", systemImage: "pencil") { editFolder(folder, folder) }
        }
    }
}
