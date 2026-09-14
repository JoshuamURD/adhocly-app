# Adhocly

A barebones, project-first todo app built with SvelteKit and Tauri. Tasks are saved locally in the browser/webview.

## Quick capture

Type a task and add optional metadata anywhere in the title:

- `#project` — project (`#Client_Work` becomes “Client Work”)
- `@tomorrow` — planned date
- `!friday` — deadline

Dates accept `today`, `tomorrow`, `nextweek`, weekday names, or `YYYY-MM-DD`. Tasks without a project go to **Inbox**.

```text
Send revised brief #Client_Work @tomorrow !friday
```

## Run

```sh
bun run dev       # browser
bun run tauri dev # desktop app
bun run check
bun test
```
