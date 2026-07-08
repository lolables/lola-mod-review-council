# User API

A simple HTTP API for looking up users and running server diagnostics.

## Endpoints

- `GET /user?id=<id>` -- look up a user by ID
- `GET /diag?cmd=<command>&args=<args>` -- run a diagnostic command
- `GET /health` -- health check
