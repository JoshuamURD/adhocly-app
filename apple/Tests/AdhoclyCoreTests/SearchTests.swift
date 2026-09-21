import Foundation
import XCTest
@testable import AdhoclyCore

final class SearchTests: XCTestCase {
    @MainActor func testSearchIncludesAllProjectsAndLiveOfflineTaskEdits() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "state.json")
        let store = try TaskStore(fileURL: url)
        let project = try store.createProject(named: "Café launch")
        let empty = try store.createProject(named: "Empty project")
        var task = TaskItem(title: "Send résumé", projectId: project.id)
        task.details = "Ask for budget approval"
        try store.save(task)
        try store.toggle(task.id)
        try store.save(TaskItem(title: "Unrelated"))

        XCTAssertEqual(store.search("  CAFE \n").projects.map(\.id), [project.id])
        XCTAssertEqual(store.search("cafe").tasks.map(\.id), [task.id])
        XCTAssertEqual(store.search("RESUME").tasks.map(\.id), [task.id])
        XCTAssertTrue(try XCTUnwrap(store.search("resume").tasks.first).completed)
        XCTAssertEqual(store.search("budget approval").tasks.map(\.id), [task.id])
        XCTAssertEqual(store.search("empty").projects.map(\.id), [empty.id])
        XCTAssertTrue(store.search("empty").tasks.isEmpty)
        for query in ["", " \n\t", "not present"] {
            XCTAssertTrue(store.search(query).projects.isEmpty)
            XCTAssertTrue(store.search(query).tasks.isEmpty)
        }

        let original = try XCTUnwrap(store.search("resume").tasks.first)
        task = original
        task.title = "Send invoice"
        task.projectId = "inbox"
        try store.save(task, replacing: original)
        XCTAssertTrue(store.search("resume").tasks.isEmpty)
        XCTAssertTrue(store.search("cafe").tasks.isEmpty)
        XCTAssertEqual(store.search("invoice").tasks.first?.projectId, "inbox")
        XCTAssertEqual(store.search("invoice").tasks.first?.details, original.details)
        XCTAssertEqual(try TaskStore(fileURL: url).search("invoice").tasks.map(\.id), [task.id])
        try store.delete(task.id)
        try store.deleteProject(empty.id)
        XCTAssertTrue(store.search("invoice").tasks.isEmpty)
        XCTAssertTrue(store.search("empty").projects.isEmpty)
    }
}
