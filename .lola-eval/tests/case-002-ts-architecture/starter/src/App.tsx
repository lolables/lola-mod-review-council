import React, { useState, useEffect, useRef } from "react";
import { Task, TaskFilter, TaskStatus, getTaskSummary } from "./types";
import { filterTasks, sortByDueDate } from "./utils";

interface AppProps {
  initialUser: string;
}

function App({ initialUser }: AppProps) {
  const [tasks, setTasks] = useState<Task[]>([]);
  const [filter, setFilter] = useState<TaskFilter>({});
  const [theme, setTheme] = useState<"light" | "dark">("light");
  const [user, setUser] = useState(initialUser);
  const [editingId, setEditingId] = useState<number | null>(null);
  const [newTitle, setNewTitle] = useState("");
  const [newAssignee, setNewAssignee] = useState("");
  const [showStats, setShowStats] = useState(false);
  const [sortOrder, setSortOrder] = useState<"date" | "status">("date");
  const [searchTerm, setSearchTerm] = useState("");

  useEffect(() => {
    const stored = localStorage.getItem("tasks");
    if (stored) {
      const parsed = JSON.parse(stored).map((t: any) => ({
        ...t,
        createdAt: new Date(t.createdAt),
        dueDate: t.dueDate ? new Date(t.dueDate) : null,
      }));
      setTasks(parsed);
    }
  }, []);

  useEffect(() => {
    localStorage.setItem("tasks", JSON.stringify(tasks));
  }, [tasks]);

  const addTask = () => {
    if (!newTitle.trim()) return;
    const task: Task = {
      id: Date.now(),
      title: newTitle,
      status: "pending",
      assignee: newAssignee || user,
      createdAt: new Date(),
      dueDate: null,
    };
    setTasks([...tasks, task]);
    setNewTitle("");
    setNewAssignee("");
  };

  const updateStatus = (id: number, status: TaskStatus) => {
    setTasks(tasks.map((t) => (t.id === id ? { ...t, status } : t)));
  };

  const deleteTask = (id: number) => {
    setTasks(tasks.filter((t) => t.id !== id));
  };

  const getFiltered = (): Task[] => {
    let result = tasks;
    if (filter.status) result = filterTasks(result, filter.status);
    if (filter.assignee)
      result = result.filter((t) => t.assignee === filter.assignee);
    if (searchTerm)
      result = result.filter((t) =>
        t.title.toLowerCase().includes(searchTerm.toLowerCase())
      );
    if (sortOrder === "date") result = sortByDueDate(result);
    return result;
  };

  const stats = {
    total: tasks.length,
    pending: tasks.filter((t) => t.status === "pending").length,
    active: tasks.filter((t) => t.status === "active").length,
    done: tasks.filter((t) => t.status === "done").length,
  };

  return (
    <div className={`app ${theme}`}>
      <header>
        <h1>Task Dashboard</h1>
        <button onClick={() => setTheme(theme === "light" ? "dark" : "light")}>
          Toggle Theme
        </button>
      </header>
      <div className="controls">
        <input
          value={newTitle}
          onChange={(e) => setNewTitle(e.target.value)}
          placeholder="New task title"
        />
        <input
          value={newAssignee}
          onChange={(e) => setNewAssignee(e.target.value)}
          placeholder="Assignee"
        />
        <button onClick={addTask}>Add Task</button>
        <input
          value={searchTerm}
          onChange={(e) => setSearchTerm(e.target.value)}
          placeholder="Search..."
        />
        <select
          value={filter.status || ""}
          onChange={(e) =>
            setFilter({
              ...filter,
              status: (e.target.value as TaskStatus) || undefined,
            })
          }
        >
          <option value="">All</option>
          <option value="pending">Pending</option>
          <option value="active">Active</option>
          <option value="done">Done</option>
        </select>
        <button onClick={() => setShowStats(!showStats)}>
          {showStats ? "Hide" : "Show"} Stats
        </button>
      </div>
      {showStats && (
        <StatsPanel stats={stats} theme={theme} user={user} />
      )}
      <TaskList
        tasks={getFiltered()}
        theme={theme}
        user={user}
        editingId={editingId}
        onEdit={setEditingId}
        onUpdateStatus={updateStatus}
        onDelete={deleteTask}
      />
    </div>
  );
}

interface StatsPanelProps {
  stats: { total: number; pending: number; active: number; done: number };
  theme: string;
  user: string;
}

function StatsPanel({ stats, theme, user }: StatsPanelProps) {
  return (
    <div className={`stats ${theme}`}>
      <h3>{user}'s Dashboard</h3>
      <p>Total: {stats.total} | Pending: {stats.pending} | Active: {stats.active} | Done: {stats.done}</p>
    </div>
  );
}

interface TaskListProps {
  tasks: Task[];
  theme: string;
  user: string;
  editingId: number | null;
  onEdit: (id: number | null) => void;
  onUpdateStatus: (id: number, status: TaskStatus) => void;
  onDelete: (id: number) => void;
}

function TaskList({
  tasks,
  theme,
  user,
  editingId,
  onEdit,
  onUpdateStatus,
  onDelete,
}: TaskListProps) {
  return (
    <div className={`task-list ${theme}`}>
      {tasks.map((task) => (
        <TaskCard
          key={task.id}
          task={task}
          theme={theme}
          user={user}
          isEditing={editingId === task.id}
          onEdit={onEdit}
          onUpdateStatus={onUpdateStatus}
          onDelete={onDelete}
        />
      ))}
    </div>
  );
}

interface TaskCardProps {
  task: Task;
  theme: string;
  user: string;
  isEditing: boolean;
  onEdit: (id: number | null) => void;
  onUpdateStatus: (id: number, status: TaskStatus) => void;
  onDelete: (id: number) => void;
}

function TaskCard({
  task,
  theme,
  user,
  isEditing,
  onEdit,
  onUpdateStatus,
  onDelete,
}: TaskCardProps) {
  const cardRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    if (cardRef.current) {
      cardRef.current.style.backgroundColor =
        theme === "dark" ? "#333" : "#fff";
      cardRef.current.style.color = theme === "dark" ? "#eee" : "#111";
      cardRef.current.style.border = `2px solid ${
        task.status === "done"
          ? "green"
          : task.status === "active"
          ? "blue"
          : "gray"
      }`;
    }
  }, [theme, task.status]);

  return (
    <div ref={cardRef} className="task-card">
      <TaskCardContent
        task={task}
        theme={theme}
        user={user}
        isEditing={isEditing}
        onEdit={onEdit}
        onUpdateStatus={onUpdateStatus}
        onDelete={onDelete}
      />
    </div>
  );
}

interface TaskCardContentProps {
  task: Task;
  theme: string;
  user: string;
  isEditing: boolean;
  onEdit: (id: number | null) => void;
  onUpdateStatus: (id: number, status: TaskStatus) => void;
  onDelete: (id: number) => void;
}

function TaskCardContent({
  task,
  theme,
  user,
  isEditing,
  onEdit,
  onUpdateStatus,
  onDelete,
}: TaskCardContentProps) {
  const summary = getTaskSummary(task);
  const isOwner = task.assignee === user;

  return (
    <div className={`card-content ${theme}`}>
      <h4>{task.title}</h4>
      <p>{summary}</p>
      <span className="assignee">Assigned to: {task.assignee}</span>
      {isOwner && (
        <div className="actions">
          {task.status !== "done" && (
            <button
              onClick={() =>
                onUpdateStatus(
                  task.id,
                  task.status === "pending" ? "active" : "done"
                )
              }
            >
              {task.status === "pending" ? "Start" : "Complete"}
            </button>
          )}
          <button onClick={() => onDelete(task.id)}>Delete</button>
        </div>
      )}
    </div>
  );
}

export default App;
