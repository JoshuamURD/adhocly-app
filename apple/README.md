# Adhocly for Mac, iPhone, and iPad

A shared SwiftUI app for macOS 14+ and iOS 17+. Requires Xcode 16 or newer. No third-party Swift dependencies and no iCloud sync.

## Run

1. Open `apple/Adhocly.xcodeproj` in Xcode. Select the **Adhocly** scheme and My Mac, an iPhone Simulator, or your device. Select your signing team under Signing & Capabilities when required.
2. Start the existing API from the repository root:

   ```sh
   cd server
   cargo run
   ```

   Rust creates and migrates its SQLite database on startup. Set `API_TOKEN` to require a bearer token. The existing server has one shared workspace, not per-user accounts; do not expose it publicly without authentication and HTTPS.

3. Run the app. In **Settings**, enter `http://localhost:3000` and the matching API token, if configured. You can create tasks before connecting.

Restart the updated Rust server before syncing. Migration `0013_context_owned_properties.sql` deletes direct task/project custom properties and property-based boards; tasks, projects, statuses, status boards, and contexts are kept. The client requires sync protocol version 7 and writes local format 9. Local upgrades discard retired property/board edits while preserving queued task, status, and context changes. Surviving request IDs and bodies stay unchanged for safe retry, so legacy property values may remain in pending requests and server receipts, but are no longer stored on tasks or projects. Older app versions cannot open format 9. Back up the database and local file before upgrading if you need the removed values.

On a physical phone, localhost means the phone itself. For trusted local development, run the API with `API_BIND=0.0.0.0:3000`, use `http://your-mac.local:3000`, and allow the local-network prompt. Find the Mac hostname with `scutil --get LocalHostName`. Use an HTTPS URL for a deployed server. The app permits plaintext HTTP only for loopback and `.local` hosts.

`mise run desktop:macos` builds and launches the Mac app, and `mise run dev:macos` starts the API and Mac app together. `mise run mobile:ios` builds and launches the Simulator app; `IOS_DEVICE` selects the simulator (default: `iPhone 17`). These tasks do not configure the app’s connection for you.

The Xcode project is checked in. If you change `project.yml`, regenerate it with `cd apple && xcodegen generate`. XcodeGen is not needed to build the checked-in project.

## Tasks and sync

- Create, edit, complete, reopen, and delete tasks offline. Add a multiline description in **Details**. Task lists and boards show a short preview and the calendar days until due (or days overdue). Set planned/due times and weekly recurrence. Create projects offline with **New project** in the Projects list, sidebar, or task editor. Inbox is available before the first connection.
- Each change reaches an atomic local file before appearing as saved. The same file holds the downloaded snapshot and pending operations. Closing the app preserves the queue; unreadable files cause a recovery error, not a reset.
- Sync runs after changes, on app activation, on manual refresh, and every 15 seconds while active. iOS can suspend the app in the background; pending work resumes when you reopen it.
- Requests use `GET /api/sync` and `POST /api/sync`, with the server’s existing entity revisions and durable mutation receipts. Retries retain their operation IDs and bodies, including after a lost response or restart. Native and non-Apple clients use the same Rust protocol.
- Conflicts and rejected changes pause uploads for review. Save the local task as a new copy or discard its pending changes. The app does not silently overwrite another device’s work. A network failure or rejected token leaves the original request queued for retry.
- Rust creates recurring successors when a task becomes complete, whether through `/toggle` or a status edit. They appear after sync. Planned/due values retain the API’s `YYYY-MM-DDTHH:MM` local wall-clock format; the client does not convert them to UTC.

Tokens live in a device-only Keychain entry scoped to the server URL. Switching servers requires an empty pending queue and replaces the downloaded cache. Local data lives at `Adhocly/state.json` in the app’s Application Support directory, inside the sandbox on installed builds. Uninstalling the app can remove unsynced data.

The client supports project creation, deletion, and folder organization, but not project renaming or user accounts. Custom fields belong to contexts, not individual projects or tasks. The legacy project metadata endpoints and task-property creation endpoint are removed. Snapshots and the single upload queue suit a personal task list. Larger datasets would need a server change cursor and incremental storage.

## Contexts

Open the **Contexts & contacts** workspace from the sidebar, or the **Contexts** tab on iPhone. The Projects directory and **More actions** also link to it. Contexts and contacts have dedicated detail, creation, and editing pages. Start with a blank context, Legal matter, or Software project, then add identifier, contact, choice, text, date, link, and long-note fields. Contacts have a name, email, phone, and notes; editing a shared contact updates every reference.

Open a context to explore project cards and related tasks, or switch to Projects or Tasks only. Search both by name or task description. Expand **Filter by property** to select effective values, including inherited values, local overrides, and **Not set** for explicit clears. All selected properties must match on the same project or task; a project also appears when one of its tasks matches. Task relationship and completion filters apply only to the task list. Expand shared information or a task's context values to inspect their sources. Inactive overrides have a separate task filter and no effective property values, so clear property filters to see them. You can edit or complete tasks, manage overrides and folder attachments, or open a project. These filters are temporary; persistent custom views are not implemented.

Right-click a task or project (long-press on iPhone/iPad), then choose **Attach context → context name** to attach it immediately. Direct attachments are checked and cannot be added twice; existing overrides are kept. Task menus work in lists, boards, the schedule, and context pages. Use a folder or project's **Contexts…** action to manage attachments and overrides. Tasks inherit attachments and field overrides through their folder ancestry and project. Open a saved task's editor to attach contexts or override individual fields. Turn off **Override** to inherit again; an explicitly empty value hides the inherited value. Attachment edits save separately from the task editor. Save a new task or project change before editing its attachments.

Task rows and cards show context names, identifiers, and client names. The task editor shows where each value came from, with expandable notes, contact details, and clickable HTTP/HTTPS links. Search also matches context names, identifiers, and contact names.

Moving work recalculates inheritance. Overrides for contexts no longer inherited stay inactive until reattached, or you remove them. Detaching locally does not suppress an ancestor's attachment. Recurring tasks copy their direct attachments and overrides. Contexts and contacts cannot be deleted while referenced; fields and choice options cannot be removed while overrides use them. Everything uses the same offline queue and conflict review as tasks.

## Search

Use **Search projects and tasks** from any workspace or the Projects/Boards directory. Search matches project names, task titles, and task descriptions across the whole workspace, including completed tasks and empty projects. It works offline and includes changes waiting to sync.

Click a project result to open it. Edit task titles inline with the same date and project shortcuts used elsewhere, or open the full editor with the sliders button. The arrow beside a task opens its project, scrolls to the task, and highlights it. Clear search to return to the current view.

## Quick task editing

Click a task in a list, board, or schedule to edit its title inline. Append `@tomorrow`, `!Monday 9am`, or `/Project name` to change its planned date, due date, or existing project; project suggestions and resolved dates appear before saving. Only explicitly supplied fields change—notes, reminders, status, and other dates stay intact. Press Return or **Save title** to save; **Cancel** or Escape discards the draft. On Mac, clicking outside the inline editor saves and closes it. Invalid shortcuts or a save failure keep the editor open with an error; clicking a suggestion or an editor action does not trigger click-away saving. Use the sliders button beside the title for the full details editor.

Right-click a task (long-press on iPhone/iPad) for **Planned date**, **Due date**, and **Move to project** menus, plus completion and deletion. Date menus offer today, tomorrow, a week ahead, a custom date/time, and removal. Presets use the configured capture time. Removing a date pauses its relative reminders without deleting them.

## Kanban

Open **By status** in the sidebar, or use **More actions → New board**. Boards group tasks by status. Search opens workspace-wide project and task results. Drag a card between columns, or use its menu’s **Move to** action with a keyboard, VoiceOver, or touch.

Use **Settings → Task statuses**, **More actions → Task statuses**, or a board’s **Edit statuses** action to add, rename, reorder, or remove statuses. Status columns are shared across boards: moving a card changes the task’s status everywhere. Statuses are separate from context fields; the API retains `/api/task-fields/status` for status edits and retry compatibility.

Every board has a special Complete column. Its name can change, but its identity and completion behavior cannot. Moving out reopens the task; completing a repeating task creates one successor on the server. The default status also has a permanent identity and can be renamed. Statuses with tasks cannot be removed until those tasks are moved elsewhere.

Board definitions, statuses, and task changes share the durable offline queue. Configuration conflicts show both versions and require an explicit choice before replacing server configuration. Deleting a board keeps its tasks.

## Capture and reminders

Put commands after the task title, in any order:

```text
Send report !Monday 9am @tomorrow /Inbox
Book dentist !two weeks from now
Prepare slides @in three days at 14:30 /"Work projects"
```

`!` sets the due date; `@` sets the planned date; `/` suggests matching projects as you type. Select a suggestion to complete the name. If the name is new, **Add** opens a prefilled **New project** modal. **Create & add task** saves both together, even offline; **Cancel** leaves the capture text unchanged. Dates are interpreted offline, and the preview shows the resolved dates before saving. The default time is 9am; change it under **Settings → Capture and reminders** on each device. Explicit times take precedence.

The English parser handles today/tomorrow, weekday names, numeric or common word-number offsets in minutes, hours, days, weeks, months, and years, ISO dates, and Apple-detected absolute dates. `Monday 9am` means the next future occurrence; `next Monday` skips today if today is Monday. Calendar arithmetic preserves wall-clock time across daylight-saving changes. Unsupported or partially parsed phrases remain in the input and prevent saving. Quotes support project names containing spaces or prefix characters; `\!`, `\@`, and `\/` keep literal prefixes in a title. Email addresses and URLs are not commands.

Both planned and due dates schedule local notifications after you grant permission. Date edits replace alerts; completion and deletion cancel them. Past dates remain valid task dates but do not schedule alerts. Alerts already scheduled can fire while the app is closed, subject to system notification settings and Focus modes.

In the task editor, use **Extra reminders → Add reminder** for extra alerts. Choose a calendar date and time, or an offset before the planned or due date. Select the unit first (days, hours, minutes, weeks, or months), then the amount (1–999). Each task supports up to 64 custom reminders alongside its two default alerts. Custom reminders save offline and sync with the task.

Relative reminders follow date edits and recurring successors. Days, weeks, and months keep local wall-clock time across daylight-saving changes. Months use calendar arithmetic: one month before March 31 is February 28 (February 29 in a leap year). Removing the anchor date pauses its relative reminders until you set it again. Fixed calendar reminders are one-off and do not copy to the next recurrence.

Turn on **Urgent** for a custom reminder to request a Time Sensitive notification. System notification and Focus settings still apply; these are not Critical Alerts and do not bypass the mute switch. Signed builds need the Time Sensitive Notifications capability enabled for the app's signing profile.

The app schedules the nearest 64 alerts and shows a warning if more are waiting. Reopening refills that schedule. Changes from another device update local alerts on the next sync; background push delivery and immediate cross-device cancellation while the app is suspended are not implemented.

## Check

```sh
# Fast Swift tests; the live-server test is skipped here.
swift test --package-path apple

# Starts an authenticated Rust server with a disposable database, runs all Swift
# tests, then stops the server. Requires Rust, Python 3, curl, and Xcode.
apple/scripts/test-integration.sh

# Optional iPhone UI smoke test (requires XcodeGen and an installed iOS runtime).
# Uses a disposable simulator and separate app identity, never your real app data.
apple/scripts/test-ui.sh

# Mac task-editor regression: multiline notes, field layout, save/reopen, and clearing notes.
# Uses a unique sandboxed app identity. Add UI_ACTION=build-for-testing to compile without launching.
UI_PLATFORM=macOS bash apple/scripts/test-ui.sh

# Compile both app destinations without provisioning.
xcodebuild -project apple/Adhocly.xcodeproj -scheme Adhocly \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
xcodebuild -project apple/Adhocly.xcodeproj -scheme Adhocly \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

Tests cover capture grammar, relative dates and DST, reminder planning, offline Kanban edits, data-file upgrades, unsupported servers, queued revisions, lost-response replay, conflict resolution, and real Rust round trips. The UI test exercises capture, notification permission, board navigation, moving a card, renaming a status, and editing custom reminders.

The integration script uses port 39373 by default; set `ADHOCLY_TEST_PORT` if occupied. Set `CARGO_TARGET_DIR` to a writable directory if the existing Rust build cache has permission issues. The UI test uses the latest installed iOS runtime and an iPhone 17 device type; override `IOS_DEVICE_TYPE` for an older Xcode installation.
