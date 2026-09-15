import type { Task } from "./api/generated";

export const weekdayNames = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"];

/** Local YYYY-MM-DD for `days` from `now`. */
export function dateFromToday(now: Date, days: number) {
  const date = new Date(now);
  date.setDate(date.getDate() + days);
  return `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, "0")}-${String(date.getDate()).padStart(2, "0")}`;
}

export function displayDate(value: string, now: Date) {
  if (value === dateFromToday(now, 0)) return "Today";
  if (value === dateFromToday(now, 1)) return "Tomorrow";
  return new Intl.DateTimeFormat(undefined, { month: "short", day: "numeric" }).format(
    new Date(`${value}T00:00:00`),
  );
}

/** Keep each task in one section, with deadlines taking priority over plans. */
export function todaySection(task: Task, today: string) {
  if (task.dueOn && task.dueOn < today) return "Overdue";
  if (task.dueOn === today) return "Due today";
  if (task.plannedFor === today) return "Planned today";
  return null;
}
