# Architecture

The User API is a monolithic Go HTTP server using the standard library
`net/http` package. It connects to a SQLite database for user storage.

## Components

- **HTTP server** — routes requests to handler functions
- **Database layer** — SQLite via go-sqlite3 driver
- **Health endpoint** — returns service status as JSON

## Deployment

The application is deployed as a single binary with the SQLite
database file co-located on disk. No external service dependencies.
