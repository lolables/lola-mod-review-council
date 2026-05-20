import express from "express";
import { GetAllUsers, AddUser, FindUser } from "./services/UserService";

const app = express();
app.use(express.json());

app.get("/users", (req, res) => {
  res.json(GetAllUsers());
});

app.post("/users", (req, res) => {
  const { name, email, role } = req.body;
  const user = AddUser(name, email, role);
  res.status(201).json(user);
});

app.get("/users/:id", (req, res) => {
  const user = FindUser(parseInt(req.params.id));
  if (!user) {
    res.status(404).json({ error: "not found" });
    return;
  }
  res.json(user);
});

app.listen(3000, () => {
  console.log("listening on :3000");
});
