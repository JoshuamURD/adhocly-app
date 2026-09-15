# Adhocly

A barebones, project-first todo app built with SvelteKit and Tauri. Tasks are persisted by a small SQLite-backed API.

## Quick capture

Type a task and add optional metadata anywhere in the title:

- `#project` — project (`#Client_Work` becomes “Client Work”)
- `@tomorrow` or `@in 2 days` — planned date
- `!friday` or `!next monday` — deadline
- `@every friday` — weekly repeat
- `@tomorrow 3pm` or `!friday 14:30` — a time on that date
- `@9am` — a bare time means the next 9am to come (tomorrow if today's has passed)

Anything after `@` or `!` is read as a date by [chrono](https://github.com/wanasit/chrono), so `today`, `tomorrow`, `nextweek`, weekdays, `next monday`, `in 2 weeks`, `jul 4`, `friday at 5pm`, and `YYYY-MM-DD` all work. Times are `3pm` or `14:30` and default to 9am when omitted. Completing a repeating task creates its next occurrence. Tasks without a project go to **Inbox**, and naming a project that does not exist yet creates it.

```text
Send revised brief #Client_Work @in 2 days !next monday
Review metrics #Reporting @every friday
```

## Projects and metadata

Projects are their own table; every task points at one, and new projects are made from the drawer or by typing
`#name` in the composer.

Metadata fields are a **shared library** — define `Client` once and every project gets that slot. Supported types:

- `text` — anything
- `number` — validated as a number by the API
- `choice` — one of the options you list for the field (one per line)

Open a project and use **Fields** to add, rename, or remove fields; values are edited inline on the project view
and saved as you leave the input. Removing a field removes its values everywhere. A field's type is fixed once
created.

Deleting a project moves its tasks to Inbox and drops its metadata. Inbox itself is seeded and cannot be deleted.

## Folders

Folders group projects in the drawer and nest as deep as you like. Drag a project, or a whole folder, onto
another folder to file it there; drop it anywhere outside a folder to put it back at the top level. Chevrons
collapse a folder, and what is collapsed is remembered between launches. Each folder row renames and deletes:
deleting a folder moves its projects and its subfolders up to the folder's parent.

Dragging needs a pointer, so project settings carries the same move as a **Folder** picker, and every folder
control is a real button.

## Run

Install the configured Bun and Rust toolchains with [mise](https://mise.jdx.dev/), then run the SQLite API and iOS app together:

```sh
mise trust
mise install
mise run dev
```

The API listens on `http://localhost:3000`, exposes `/health`, `/openapi.json`, `/api/tasks`,
`/api/projects`, `/api/folders`, and `/api/metadata-fields`, and stores its SQLite database at `~/.local/state/adhocly/adhocly.db` when run through mise. Vite proxies `/api` during development; set `PUBLIC_API_URL` to the API origin, e.g. `http://192.168.1.20:3000`, when the API is hosted separately.

OpenAPI is generated from the Rust handlers with `utoipa`; Orval turns `server/openapi.json` into `src/lib/api/generated.ts`:

```sh
bun run api:gen
```

`mise run server` also serves that spec as browsable [Scalar](https://scalar.com) docs on
`http://localhost:3001`. The docs task watches `server/openapi.json`, so `api:gen` updates the page live;
the first run downloads the Scalar CLI. The spec's `servers` entry is what the docs' **Test Request** sends
to, so requests from the docs only reach an API running at `http://localhost:3000`.

## iOS offline sync

The iOS app stores a server snapshot and an ordered outbox together in one SQLite record. A local
mutation commits that record in a single statement; reads rebuild the snapshot with pending changes
applied. Server pulls cannot overwrite unsynced work. Local queries and mutations run even when
TanStack considers the device offline.

`GET /api/sync` returns a transactionally consistent snapshot with entity revisions. `POST /api/sync`
accepts a mutation ID, URL, method, body, and expected revision. The server checks the revision and
commits the business write and its retry receipt in the **same transaction**. Replaying an identical
mutation returns its receipt without rewriting the entity; reusing an ID for another request or
writing against an old revision returns 409. SQLite triggers track revisions for direct browser/
desktop writes and cascades too. Direct browser/desktop API calls otherwise keep their existing behavior.

After acknowledgement, the client atomically removes the operation and updates its baseline, rebasing
later operations only onto that operation's own effects. Each repeating task has one canonical
`next:{taskId}` successor across devices. Repeated completions do not overwrite that successor, and
server tombstones prevent recreating a deleted successor.

Sync runs at launch, native resume, foreground/reconnect, after writes, and on demand. Requests time
out after 20 seconds; transient failures retry while foregrounded with backoff from 2 to 60 seconds.
Permanent conflicts retain the queued data and still allow remote snapshots to refresh. The sync
control shows the queued change and last fetched server version; users can retry, rename, explicitly
keep their change against the reviewed revision, or discard it. Discarding a create warns about and
removes dependent queued changes rather than leaving dangling references.

**Upgrade the server before the iOS app.** Existing unversioned outbox entries are imported but require
explicit review; they are never blindly replayed. The previous cache/outbox remain untouched as a
recovery backup in `adhocly-offline.db`. Do not clear app storage to resolve a sync error. A saved
outbox is bound to its API origin and will not be sent to a different server.

Full snapshots, whole-document local commits, and retained receipts/tombstones are deliberate choices
for a personal app. Do not prune receipts or tombstones without a device-acknowledgement protocol;
add incremental replication only when the dataset warrants it. Sync does not require or promise
execution while iOS has suspended the app.


Individual commands:

```sh
mise run server       # backend only, plus Scalar API docs on :3001
mise run api:docs     # Scalar API docs only
mise run mobile:ios   # iOS app only
mise run api:gen      # regenerate OpenAPI + frontend client
bun run dev           # browser
bun run tauri dev     # desktop app
bun run check         # regenerates API client, then typechecks
bun test
```
