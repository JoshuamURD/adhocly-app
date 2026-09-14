/** @typedef {{ title: string, project: string | null, plannedFor: string | null, dueOn: string | null }} ParsedTaskInput */

const weekdays = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"];

/** @param {Date} date */
function formatDate(date) {
  const year = date.getFullYear();
  const month = String(date.getMonth() + 1).padStart(2, "0");
  const day = String(date.getDate()).padStart(2, "0");
  return `${year}-${month}-${day}`;
}

/** @param {string} value @param {Date} now */
function parseDate(value, now) {
  const token = value.toLowerCase();
  const date = new Date(now.getFullYear(), now.getMonth(), now.getDate());

  if (/^\d{4}-\d{2}-\d{2}$/.test(token)) {
    const [year, month, day] = token.split("-").map(Number);
    const candidate = new Date(year, month - 1, day);
    return candidate.getFullYear() === year && candidate.getMonth() === month - 1 && candidate.getDate() === day
      ? token
      : null;
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

/**
 * Parses @date, !date, and #project tokens from a task title.
 * Supported dates: today, tomorrow, nextweek, weekdays, and YYYY-MM-DD.
 * @param {string} input
 * @param {Date} [now]
 * @returns {ParsedTaskInput}
 */
export function parseTaskInput(input, now = new Date()) {
  let plannedFor = null;
  let dueOn = null;
  let project = null;

  const title = input
    .replace(/(^|\s)([@!])([a-z]+|\d{4}-\d{2}-\d{2})(?=\s|$)/gi, (match, space, marker, token) => {
      const date = parseDate(token, now);
      if (!date) return match;
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

  return { title, project, plannedFor, dueOn };
}
