# Adhocly

A barebones, project-first todo app built with SvelteKit and Tauri. Tasks are persisted by a small SQLite-backed API.

## Quick capture

Type a task and add optional metadata anywhere in the title:

- `#project` — project (`#Client_Work` becomes “Client Work”)
- `@tomorrow` or `@in 2 days` — planned date
- `!friday` or `!next monday` — deadline
- `@every friday` — weekly repeat

Dates accept `today`, `tomorrow`, `nextweek`, weekdays, `next <weekday>`, `in <number> days/weeks/months/years`, or `YYYY-MM-DD`. Completing a repeating task creates its next occurrence. Tasks without a project go to **Inbox**.

```text
Send revised brief #Client_Work @in 2 days !next monday
Review metrics #Reporting @every friday
```

## Run

Install the configured Bun and Rust toolchains with [mise](https://mise.jdx.dev/), then run the SQLite API and iOS app together:

```sh
mise trust
mise install
mise run dev
```

The API listens on `http://localhost:3000`, exposes `/health`, `/openapi.json`, and `/api/tasks`, and stores its SQLite database at `~/.local/state/adhocly/adhocly.db` when run through mise. Vite proxies `/api` during development; set `PUBLIC_API_URL` to the API origin, e.g. `http://192.168.1.20:3000`, when the API is hosted separately.

OpenAPI is generated from the Rust handlers with `utoipa`; Orval turns `server/openapi.json` into `src/lib/api/generated.ts`:

```sh
bun run api:gen
```

Individual commands:

```sh
mise run server       # backend only
mise run mobile:ios   # iOS app only
mise run api:gen      # regenerate OpenAPI + frontend client
bun run dev           # browser
bun run tauri dev     # desktop app
bun run check         # regenerates API client, then typechecks
bun test
```
