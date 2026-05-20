import { IUser } from "./user";

export interface IOrder {
  id: number;
  user: IUser;
  items: string[];
  total: number;
  status: string;
}

export function ProcessOrder(order: any, discount: any): any {
  const total = order.total - (order.total * discount);
  return { ...order, total, status: "processed" };
}
