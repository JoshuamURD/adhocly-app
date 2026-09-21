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
    @State private var searchPresented = false
    @State private var selectedTab = "tasks"
    @State private var revealedTask: TaskItem?
    @State private var today = Date()
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("todaySort") private var todaySort = TodayTaskOrder.due
    @AppStorage("todayGrouping") private var todayGrouping = ""
    @AppStorage("tomorrowSort") private var tomorrowSort = TodayTaskOrder.due
    @AppStorage("tomorrowGrouping") private var tomorrowGrouping = ""
    @AppStorage("thisWeekSort") private var thisWeekSort = TodayTaskOrder.due
    @AppStorage("thisWeekGrouping") private var thisWeekGrouping = ""
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

    private var isSearching: Bool { !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private func board(for scope: String) -> KanbanBoard? {
        guard scope.hasPrefix("board:") else { return nil }
        return store.boards.first { $0.id == String(scope.dropFirst(6)) }
    }

    private func tasks(for scope: String) -> [TaskItem] {
        let scopedTasks = TaskDateWindow(rawValue: scope).map { TodayTasks.matching(store.tasks, in: $0, now: today) } ?? store.tasks
        return scopedTasks.filter { task in
            let matches: Bool
            switch scope {
            case "active": matches = !task.completed
            case "completed": matches = task.completed
            case let value where value.hasPrefix("project:"):
                matches = task.projectId == String(value.dropFirst(8))
            default: matches = true
            }
            return matches
        }
    }

    private func title(for scope: String) -> String {
        if let board = board(for: scope) { return board.name }
        if scope.hasPrefix("project:") {
            return store.projects.first { $0.id == String(scope.dropFirst(8)) }?.name ?? "Project"
        }
        if scope == "schedule" { return "Schedule" }
        if let window = TaskDateWindow(rawValue: scope) { return window.name }
        return scope == "completed" ? "Completed" : scope == "all" ? "All tasks" : "To do"
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
        .onChange(of: search) { _, _ in
            if isSearching { revealedTask = nil }
        }
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
        .alert("Delete project?", isPresented: Binding(
            get: { deletingProject != nil }, set: { if !$0 { deletingProject = nil } }
        )) {
            Button("Cancel", role: .cancel) { deletingProject = nil }
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
                    ForEach(TaskDateWindow.allCases, id: \.self) { window in
                        sidebarLink(window.name, symbol: window == .today ? "sun.max" : window == .tomorrow ? "sunrise" : "calendar.badge.clock",
                                    scope: window.rawValue, count: tasks(for: window.rawValue).count)
                    }
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
            #if os(macOS)
            .buttonStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(AppStyle.canvas)
            .environment(\.defaultMinListRowHeight, 32)
            .safeAreaInset(edge: .top, spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.square.fill")
                        .font(.title2).foregroundStyle(.primary)
                        .accessibilityHidden(true)
                    Text("Adhocly").font(.system(size: 16, weight: .semibold))
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 20)
            }
            #else
            .navigationTitle("Adhocly")
            #endif
            .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 300)
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 12) {
                    #if os(iOS)
                    Label("A little space for what’s next.", systemImage: "leaf")
                        .font(.caption).foregroundStyle(.secondary)
                    #endif
                    Button { showConnection = true } label: {
                        Label("Settings & sync", systemImage: "gearshape")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Settings")
                }
                .padding(20)
                #if os(macOS)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(AppStyle.canvas)
                .overlay(alignment: .top) { Divider() }
                #endif
            }
        } detail: {
            workspace(selection ?? "active")
        }
        .navigationSplitViewStyle(.balanced)
    }

    #if os(iOS)
    private var phoneNavigation: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                workspace(taskFilter, showFilter: true)
            }
            .tabItem { Label("Tasks", systemImage: "checklist") }
            .tag("tasks")
            NavigationStack {
                workspace("schedule")
            }
            .tabItem { Label("Schedule", systemImage: "calendar") }
            .tag("schedule")
            NavigationStack {
                directory(isBoards: true)
                    .navigationDestination(for: String.self) { workspace($0) }
            }
            .tabItem { Label("Boards", systemImage: "rectangle.split.3x1") }
            .tag("boards")
            NavigationStack(path: $projectPath) {
                directory(isBoards: false)
                    .navigationDestination(for: String.self) { workspace($0) }
            }
            .tabItem { Label("Projects", systemImage: "folder") }
            .tag("projects")
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
                        #if os(macOS)
                        .frame(minWidth: 22)
                        .padding(.vertical, 2)
                        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 4))
                        #endif
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
        Group {
            if isSearching { searchResults }
            else { directoryContent(isBoards: isBoards) }
        }
        .background(AppStyle.canvas)
        .navigationTitle(isBoards ? "Boards" : "Projects")
        .searchable(text: $search, isPresented: $searchPresented, prompt: "Search projects and tasks")
    }

    private func directoryContent(isBoards: Bool) -> some View {
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
            if isSearching {
                searchResults
            } else {
                if scope != "schedule" {
                    WorkspaceHeading(title: title(for: scope), subtitle: subtitle(for: scope, count: visibleTasks.count))
                }
                if showFilter {
                    Picker("Show tasks", selection: $taskFilter) {
                        Text("To do").tag("active")
                        ForEach(TaskDateWindow.allCases, id: \.self) { window in
                            Text(window.name).tag(window.rawValue)
                        }
                        Text("All").tag("all")
                        Text("Completed").tag("completed")
                    }
                    .pickerStyle(.menu)
                    .accessibilityIdentifier("workspace-filter")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 12)
                }
                if TaskDateWindow(rawValue: scope) != nil { dateControls(scope: scope) }
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
        }
        .background(AppStyle.canvas)
        .onPreferenceChange(TaskTitleEditingKey.self) { editingTitle = $0 }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !editingTitle && !isSearching { captureBar(scope: scope) }
        }
        .navigationTitle(title(for: scope))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .searchable(text: $search, isPresented: $searchPresented, prompt: "Search projects and tasks")
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

    private var searchResults: some View {
        let results = store.search(search)
        return VStack(spacing: 0) {
            WorkspaceHeading(title: "Search results", subtitle: "All projects · Including completed tasks")
            List {
                if !results.projects.isEmpty {
                    Section("Projects (\(results.projects.count))") {
                        ForEach(results.projects) { project in
                            Button { openProject(project.id) } label: {
                                HStack {
                                    directoryRow(project.name,
                                                 subtitle: project.folderId.map { store.folderPath($0) } ?? "Top level",
                                                 symbol: project.id == "inbox" ? "tray" : "folder")
                                    Spacer()
                                    Image(systemName: "chevron.right").foregroundStyle(.secondary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(editingTitle)
                            .accessibilityLabel("Open project \(project.name)")
                            .listRowBackground(AppStyle.surface)
                        }
                    }
                }
                if !results.tasks.isEmpty {
                    Section("Tasks (\(results.tasks.count))") {
                        taskRows(results.tasks, showLocation: true)
                    }
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            #if os(macOS)
            .background(AppStyle.surface)
            #endif
            .scrollDismissesKeyboard(.interactively)
            .overlay {
                if results.projects.isEmpty && results.tasks.isEmpty {
                    ContentUnavailableView {
                        Label("No matching projects or tasks", systemImage: "magnifyingglass")
                    } description: {
                        Text("Try another title, detail, or project name.")
                    } actions: {
                        Button("Clear search") { search = "" }
                    }
                }
            }
        }
        .onPreferenceChange(TaskTitleEditingKey.self) { editingTitle = $0 }
    }

    private func openProject(_ id: String, revealing task: TaskItem? = nil) {
        search = ""
        searchPresented = false
        revealedTask = task
        selection = "project:\(id)"
        projectPath = ["project:\(id)"]
        selectedTab = "projects"
    }

    private func subtitle(for scope: String, count: Int) -> String {
        if let window = TaskDateWindow(rawValue: scope), window != .today {
            return "\(count) \(count == 1 ? "task" : "tasks") planned or due \(window.dateDescription)."
        }
        #if os(macOS)
        if let board = board(for: scope) {
            return "Grouped by \(store.taskFields.first { $0.id == board.fieldId }?.name ?? "property") · \(count) tasks"
        }
        if scope == "today" { return today.formatted(.dateTime.weekday(.wide).month(.wide).day()) }
        return "\(count) \(count == 1 ? "task" : "tasks")\(scope == "completed" ? " completed" : "")"
        #else
        if board(for: scope) != nil { return "Move work forward, one card at a time." }
        if scope == "completed" { return "A record of what you’ve taken care of." }
        if scope == "today" { return "\(count) \(count == 1 ? "task" : "tasks") planned or due today." }
        return count == 0 ? "Make room for your next idea." : "\(count) \(count == 1 ? "task" : "tasks") · One thing at a time."
        #endif
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

    private func dateSort(for scope: String) -> Binding<TodayTaskOrder> {
        switch TaskDateWindow(rawValue: scope) {
        case .tomorrow: $tomorrowSort
        case .thisWeek: $thisWeekSort
        default: $todaySort
        }
    }

    private func dateGrouping(for scope: String) -> Binding<String> {
        switch TaskDateWindow(rawValue: scope) {
        case .tomorrow: $tomorrowGrouping
        case .thisWeek: $thisWeekGrouping
        default: $todayGrouping
        }
    }

    private func dateControls(scope: String) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack { dateSortMenu(scope: scope); dateGroupMenu(scope: scope); Spacer() }
            VStack(alignment: .leading) { dateSortMenu(scope: scope); dateGroupMenu(scope: scope) }
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.subheadline)
        .padding(.horizontal, 24)
        .padding(.bottom, 12)
        #if os(macOS)
        .padding(.top, 12)
        .background(AppStyle.surface)
        .overlay(alignment: .bottom) { Divider() }
        #endif
    }

    private func dateSortMenu(scope: String) -> some View {
        let sort = dateSort(for: scope)
        return Menu {
            Picker("Sort by", selection: sort) {
                ForEach(TodayTaskOrder.allCases, id: \.self) { Text($0.name).tag($0) }
            }
        } label: {
            Label("Sort: \(sort.wrappedValue.name)", systemImage: "arrow.up.arrow.down")
        }
        .accessibilityIdentifier("\(scope)-sort")
    }

    private func dateGroupMenu(scope: String) -> some View {
        let grouping = dateGrouping(for: scope)
        return Menu {
            Picker("Group by", selection: grouping) {
                Text("None").tag("")
                ForEach(TodayTaskOrder.allCases, id: \.self) { Text($0.name).tag($0.rawValue) }
            }
        } label: {
            Label("Group: \(TodayTaskOrder(rawValue: grouping.wrappedValue)?.name ?? "None")", systemImage: "rectangle.3.group")
        }
        .accessibilityIdentifier("\(scope)-group")
    }

    private func taskRows(_ tasks: [TaskItem], showLocation: Bool = false) -> some View {
        ForEach(tasks) { task in
            taskRow(task, showLocation: showLocation)
                .id(task.id)
                .listRowBackground(revealedTask?.id == task.id ? Color.accentColor.opacity(0.12) : AppStyle.surface)
                .listRowSeparatorTint(AppStyle.border)
                #if os(macOS)
                .listRowInsets(EdgeInsets(top: 2, leading: 20, bottom: 2, trailing: 20))
                #endif
                .swipeActions {
                    Button("Delete", role: .destructive) { model.perform { try store.delete(task.id) } }
                    Button("Edit") { editor = EditorRequest(draft: task, original: task) }
                }
        }
    }

    private func taskList(_ tasks: [TaskItem], scope: String) -> some View {
        let window = TaskDateWindow(rawValue: scope)
        let sort = dateSort(for: scope).wrappedValue
        let grouping = TodayTaskOrder(rawValue: dateGrouping(for: scope).wrappedValue)
        return ScrollViewReader { proxy in
            List {
                if window != nil, let grouping {
                    ForEach(TodayTasks.groups(tasks, by: grouping, sort: sort, statuses: store.statusField.options)) { group in
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
                    taskRows(window != nil ? TodayTasks.sorted(tasks, by: sort, statuses: store.statusField.options) : tasks)
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            #if os(macOS)
            .background(AppStyle.surface)
            #endif
            .scrollDismissesKeyboard(.interactively)
            .task(id: revealedTask?.id) {
                if let task = revealedTask, scope == "project:\(task.projectId)" {
                    await Task.yield()
                    proxy.scrollTo(task.id, anchor: .center)
                }
            }
            .overlay {
                if tasks.isEmpty {
                    ContentUnavailableView {
                        #if os(macOS)
                        Label(window.map { "Nothing scheduled \($0.dateDescription)" } ?? (scope == "completed" ? "No completed tasks" : "No tasks here"),
                              systemImage: scope == "completed" ? "checkmark.circle" : "tray")
                        #else
                        Label(window.map { "Nothing planned or due \($0.dateDescription)" } ?? (scope == "completed" ? "Good things take a first step" : "A little room to think"),
                              systemImage: "leaf")
                            .foregroundStyle(Color.accentColor)
                        #endif
                    } description: {
                        Text(window.map { "Tasks with a planned or due date \($0.dateDescription) will appear here." } ?? (scope == "completed" ? "Completed tasks will appear here." : "Capture an idea below, or add a task with more detail."))
                    } actions: {
                        if scope != "completed" {
                            Button("Create a task") { editor = EditorRequest(draft: newTask(in: scope), original: nil) }
                                .buttonStyle(.borderedProminent)
                        }
                    }
                }
            }
        }
    }

    private func taskRow(_ task: TaskItem, showLocation: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Button { model.perform { try store.toggle(task.id) } } label: {
                Image(systemName: task.completed ? "checkmark.circle.fill" : "circle")
                    #if os(macOS)
                    .font(.system(size: 18, weight: .light))
                    #else
                    .font(.title2.weight(.light))
                    #endif
                    .foregroundStyle(task.completed ? Color.accentColor : Color.secondary)
                    .frame(width: AppStyle.controlSide, height: AppStyle.controlSide)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(task.completed ? "Mark \(task.title) incomplete" : "Complete \(task.title)")
            TaskQuickEdit(model: model, store: store, task: task,
                          editDetails: { editor = EditorRequest(draft: $0, original: $0) }) {
                VStack(alignment: .leading, spacing: 7) {
                    #if os(macOS)
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(task.title)
                            .font(.body.weight(.medium))
                            .strikethrough(task.completed)
                            .foregroundStyle(task.completed ? .secondary : .primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(store.statusName(task.statusId))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(AppStyle.canvas, in: RoundedRectangle(cornerRadius: 4))
                    }
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 12) { taskMetadata(task) }
                        VStack(alignment: .leading, spacing: 5) { taskMetadata(task) }
                    }
                    if !task.details.isEmpty {
                        Text(task.details).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    #else
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
                    #endif
                }
                #if os(macOS)
                .padding(.vertical, 5)
                #else
                .padding(.vertical, 10)
                #endif
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            if showLocation {
                Button { openProject(task.projectId, revealing: task) } label: {
                    Image(systemName: "arrow.up.forward")
                        .frame(width: AppStyle.controlSide, height: AppStyle.controlSide)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(editingTitle)
                .accessibilityLabel("Show \(task.title) in \(task.project)")
                .help("Show in \(task.project)")
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

    #if os(macOS)
    @ViewBuilder private func taskMetadata(_ task: TaskItem) -> some View {
        Text(task.project).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        if let planned = task.plannedFor { TaskDateLabel(value: planned, completed: task.completed) }
        if let due = task.dueOn { TaskDateLabel(value: due, isDue: true, completed: task.completed) }
        if task.repeatWeekday != nil {
            Image(systemName: "repeat").font(.caption).foregroundStyle(.secondary)
                .accessibilityLabel("Repeats weekly")
        }
    }
    #endif

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
