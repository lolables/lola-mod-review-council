export type userRole = "admin" | "member" | "guest";

export interface IUser {
  id: number;
  name: string;
  email: string;
  role: userRole;
  createdAt: Date;
}

export function CreateUser(name: string, email: string, role: any): IUser {
  return {
    id: Date.now(),
    name,
    email,
    role,
    createdAt: new Date(),
  };
}
