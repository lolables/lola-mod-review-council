import { formatDate } from "./utils";

export type TaskStatus = "pending" | "active" | "done";

export interface Task {
  id: number;
  title: string;
  status: TaskStatus;
  assignee: string;
  createdAt: Date;
  dueDate: Date | null;
}

export interface TaskFilter {
  status?: TaskStatus;
  assignee?: string;
  search?: string;
}

export function getTaskSummary(task: Task): string {
  return `${task.title} (${task.status}) — due ${formatDate(task.dueDate)}`;
}
