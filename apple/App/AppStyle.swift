import AdhoclyCore
import SwiftUI

enum AppStyle {
    static let canvas = Color("Canvas")
    static let surface = Color("Surface")
    static let border = Color.primary.opacity(0.09)
    #if os(macOS)
    static let controlSide: CGFloat = 28
    static let cardRadius: CGFloat = 8
    static let captureRadius: CGFloat = 8
    static let headingFont = Font.custom("HelveticaNeue-Medium", size: 26, relativeTo: .largeTitle)
    static let editorFont = Font.system(.title2, weight: .semibold)
    #else
    static let controlSide: CGFloat = 44
    static let cardRadius: CGFloat = 14
    static let captureRadius: CGFloat = 16
    static let headingFont = Font.system(.largeTitle, design: .serif, weight: .medium)
    static let editorFont = Font.system(.title2, design: .serif, weight: .medium)
    #endif
}

struct WorkspaceHeading: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(AppStyle.headingFont)
                .accessibilityAddTraits(.isHeader)
            Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 24)
        #if os(macOS)
        .padding(.top, 28)
        .padding(.bottom, 20)
        .background(AppStyle.surface)
        .overlay(alignment: .bottom) { Divider() }
        #else
        .padding(.top, 20)
        .padding(.bottom, 16)
        #endif
    }
}

struct TaskDateLabel: View {
    let value: String
    var isDue = false
    var completed = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let date = LocalDateTime.date(from: value)
            let overdue = isDue && !completed && date.map { $0 < context.date } == true
            let caption = isDue && !completed
                ? date.map { LocalDateTime.dueLabel(for: $0, now: context.date) } ?? "Due"
                : isDue ? "Due" : "Planned"
            Label {
                Text("\(caption) · \(date?.formatted(date: .abbreviated, time: .shortened) ?? value)")
            } icon: {
                Image(systemName: isDue ? "flag" : "calendar")
            }
            .font(.caption)
            .foregroundStyle(overdue ? Color.red : Color.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct WorkspaceIcon: View {
    let symbol: String

    var body: some View {
        Image(systemName: symbol)
            .font(.title3)
            .foregroundStyle(.tint)
            .frame(width: 44, height: 44)
            .background(Color.accentColor.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
            .accessibilityHidden(true)
    }
}
