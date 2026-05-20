import { Task, TaskStatus } from "./types";

export function formatDate(date: Date | null): string {
  if (!date) return "no date";
  return date.toLocaleDateString();
}

export function filterTasks(tasks: Task[], status: TaskStatus): Task[] {
  return tasks.filter((t) => t.status === status);
}

export function sortByDueDate(tasks: Task[]): Task[] {
  return [...tasks].sort((a, b) => {
    if (!a.dueDate) return 1;
    if (!b.dueDate) return -1;
    return a.dueDate.getTime() - b.dueDate.getTime();
  });
}
