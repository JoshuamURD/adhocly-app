export type ParsedTaskInput = {
  title: string;
  project: string | null;
  plannedFor: string | null;
  dueOn: string | null;
  repeatWeekday: number | null;
};

const weekdays = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"];
const dateToken = /(^|\s)([@!])(\d{4}-\d{2}-\d{2}|today|tomorrow|nextweek|sunday|monday|tuesday|wednesday|thursday|friday|saturday|next\s+(?:sunday|monday|tuesday|wednesday|thursday|friday|saturday)|in\s+(?:\d+|one|two)\s+(?:days?|weeks?|months?|years?)|every\s+(?:sunday|monday|tuesday|wednesday|thursday|friday|saturday))(?=\s|$)/gi;

function formatDate(date: Date): string {
  const year = date.getFullYear();
  const month = String(date.getMonth() + 1).padStart(2, "0");
  const day = String(date.getDate()).padStart(2, "0");
  return `${year}-${month}-${day}`;
}

function addMonths(date: Date, months: number): void {
  const day = date.getDate();
  date.setDate(1);
  date.setMonth(date.getMonth() + months);
  date.setDate(Math.min(day, new Date(date.getFullYear(), date.getMonth() + 1, 0).getDate()));
}

function parseDate(value: string, now: Date): string | null {
  const token = value.toLowerCase();
  const date = new Date(now.getFullYear(), now.getMonth(), now.getDate());

  if (/^\d{4}-\d{2}-\d{2}$/.test(token)) {
    const [year, month, day] = token.split("-").map(Number);
    const candidate = new Date(year, month - 1, day);
    return candidate.getFullYear() === year && candidate.getMonth() === month - 1 && candidate.getDate() === day
      ? token
      : null;
  }

  const relative = /^in (\d+|one|two) (days?|weeks?|months?|years?)$/.exec(token);
  if (relative) {
    const amount = { one: 1, two: 2 }[relative[1] as "one" | "two"] ?? Number(relative[1]);
    if (!Number.isSafeInteger(amount) || amount < 1) return null;

    if (relative[2].startsWith("day")) date.setDate(date.getDate() + amount);
    else if (relative[2].startsWith("week")) date.setDate(date.getDate() + amount * 7);
    else addMonths(date, amount * (relative[2].startsWith("year") ? 12 : 1));
    return formatDate(date);
  }

  const nextWeekday = /^next (.+)$/.exec(token)?.[1];
  if (nextWeekday) {
    const weekday = weekdays.indexOf(nextWeekday);
    if (weekday < 0) return null;
    date.setDate(date.getDate() + 7 - date.getDay() + weekday);
    return formatDate(date);
  }

  if (token === "tomorrow") date.setDate(date.getDate() + 1);
  else if (token === "nextweek") date.setDate(date.getDate() + 7);
  else if (token !== "today") {
    const weekday = weekdays.indexOf(token);
    if (weekday < 0) return null;
    date.setDate(date.getDate() + ((weekday - date.getDay() + 6) % 7) + 1);
  }

  return formatDate(date);
}

export function nextWeeklyDate(value: string | null): string | null {
  if (!value) return null;
  const [year, month, day] = value.split("-").map(Number);
  const date = new Date(year, month - 1, day);
  if (date.getFullYear() !== year || date.getMonth() !== month - 1 || date.getDate() !== day) return null;
  date.setDate(date.getDate() + 7);
  return formatDate(date);
}

/**
 * Parses prefixed dates, repeats, and #project tokens from a task title.
 */
export function parseTaskInput(input: string, now: Date = new Date()): ParsedTaskInput {
  let plannedFor: string | null = null;
  let dueOn: string | null = null;
  let project: string | null = null;
  let repeatWeekday: number | null = null;

  const title = input
    .replace(dateToken, (match, space, marker, token) => {
      const normalized = token.toLowerCase();
      const repeatedDay = /^every (.+)$/.exec(normalized)?.[1];
      const date = parseDate(repeatedDay ?? normalized, now);
      if (!date) return match;
      if (repeatedDay) repeatWeekday = weekdays.indexOf(repeatedDay);
      if (marker === "@") plannedFor = date;
      else dueOn = date;
      return space;
    })
    .replace(/(^|\s)#([\w-]+)(?=\s|$)/g, (_match, space, name) => {
      project = name.replaceAll("_", " ");
      return space;
    })
    .replace(/\s+/g, " ")
    .trim();

  return { title, project, plannedFor, dueOn, repeatWeekday };
}
