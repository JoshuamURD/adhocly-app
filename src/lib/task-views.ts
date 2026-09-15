import type { Task } from "./api/generated";

export const weekdayNames = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"];

const dateFormat = new Intl.DateTimeFormat(undefined, { month: "short", day: "numeric" });
const timeFormat = new Intl.DateTimeFormat(undefined, { hour: "2-digit", minute: "2-digit" });

/** Local YYYY-MM-DD for `days` from `now`. */
export function dateFromToday(now: Date, days: number) {
  const date = new Date(now);
  date.setDate(date.getDate() + days);
  return `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, "0")}-${String(date.getDate()).padStart(2, "0")}`;
}

/** The YYYY-MM-DD half of a `YYYY-MM-DDTHH:MM` value. */
export function datePart(value: string) {
  return value.slice(0, 10);
}

export function displayDate(value: string, now: Date) {
  const [date, time] = value.split("T");
  const name =
    date === dateFromToday(now, 0)
      ? "Today"
      : date === dateFromToday(now, 1)
        ? "Tomorrow"
        : dateFormat.format(new Date(`${date}T00:00:00`));
  // Read back as a local wall clock, matching how the value was captured.
  return time ? `${name} ${timeFormat.format(new Date(`${date}T${time}:00`))}` : name;
}

/** Keep each task in one section, with deadlines taking priority over plans. */
export function todaySection(task: Task, today: string) {
  const due = task.dueOn && datePart(task.dueOn);
  const planned = task.plannedFor && datePart(task.plannedFor);
  if (due && due < today) return "Overdue";
  if (due === today) return "Due today";
  if (planned === today) return "Planned today";
  return null;
}
