import type { Task } from "./api/generated";

/** Keep each task in one section, with deadlines taking priority over plans. */
export function todaySection(task: Task, today: string) {
  if (task.dueOn && task.dueOn < today) return "Overdue";
  if (task.dueOn === today) return "Due today";
  if (task.plannedFor === today) return "Planned today";
  return null;
}
