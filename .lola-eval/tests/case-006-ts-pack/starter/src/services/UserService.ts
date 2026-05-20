import { IUser, CreateUser, userRole } from "../models";

var users: IUser[] = [];

export function GetAllUsers(): any {
  return users;
}

export function AddUser(name: string, email: string, role: any) {
  const user = CreateUser(name, email, role);
  users.push(user);
  return user;
}

export function FindUser(id: number) {
  return users.find((u) => u.id === id);
}
