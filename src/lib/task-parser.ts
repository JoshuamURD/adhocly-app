// ponytail: English-only. Import a locale module (or drop /en for every bundled locale) when the app is translated.
import { casual } from "chrono-node/en";

export type ParsedTaskInput = {
  title: string;
  project: string | null;
  plannedFor: string | null;
  dueOn: string | null;
  repeatWeekday: number | null;
};

const DEFAULT_TIME = "09:00";
const markerToken = /(^|\s)([@!])/g;
const projectToken = /(^|\s)#([\w-]+)(?=\s|$)/g;
const everyPrefix = /^every\s+/i;

/** `YYYY-MM-DDTHH:MM` local wall clock; a date without a stated time takes the 09:00 default. */
function wallClock(date: Date, hasTime: boolean): string {
  const pad = (value: number) => String(value).padStart(2, "0");
  const day = `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}`;
  return hasTime ? `${day}T${pad(date.getHours())}:${pad(date.getMinutes())}` : `${day}T${DEFAULT_TIME}`;
}

/** How chrono reads the start of `text`, and how much of it that reading covers. */
function parseWhen(text: string, now: Date) {
  const result = casual.parse(text, now, { forwardDate: true }).find((parsed) => parsed.index === 0);
  if (!result) return null;
  const date = result.start.date();
  return { date, value: wallClock(date, result.start.isCertain("hour")), length: result.text.length };
}

/**
 * Parses prefixed dates, repeats, and #project tokens from a task title.
 * Dates carry a local wall clock time, defaulting to 09:00. A bare time means the next one to come,
 * so `@9am` at 10am reads as tomorrow morning.
 */
export function parseTaskInput(input: string, now: Date = new Date()): ParsedTaskInput {
  let plannedFor: string | null = null;
  let dueOn: string | null = null;
  let project: string | null = null;
  let repeatWeekday: number | null = null;
  /** Character ranges consumed by recognised tokens, removed from the title at the end. */
  const consumed: [number, number][] = [];

  for (const match of input.matchAll(markerToken)) {
    const marker = match.index! + match[1].length;
    const body = input.slice(marker + 1);
    const every = everyPrefix.exec(body)?.[0] ?? "";
    const when = parseWhen(body.slice(every.length), now);
    if (!when) continue;

    consumed.push([marker, marker + 1 + every.length + when.length]);
    if (every) repeatWeekday = when.date.getDay();
    if (match[2] === "@") plannedFor = when.value;
    else dueOn = when.value;
  }

  for (const match of input.matchAll(projectToken)) {
    project = match[2].replaceAll("_", " ");
    consumed.push([match.index! + match[1].length, match.index! + match[0].length]);
  }

  let title = "";
  let cursor = 0;
  for (const [start, end] of consumed.sort((a, b) => a[0] - b[0])) {
    if (start < cursor) continue;
    title += input.slice(cursor, start);
    cursor = end;
  }
  title += input.slice(cursor);

  return { title: title.replace(/\s+/g, " ").trim(), project, plannedFor, dueOn, repeatWeekday };
}
