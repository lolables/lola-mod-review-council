# flagsvc

A small feature-flag service. Clients read flags; operators change them.

## Endpoints

- `GET /flags` — list every flag and whether it is enabled. Public.
- `PUT /admin/flags/{name}` — set a flag. Body: `{"enabled": true}`.
  Admin endpoints require `Authorization: Bearer <key>`, where `<key>` is
  the configured `admin_key`.

## Configuration

`flagsvc -config config.json` reads a JSON file:

| Key               | Meaning                                                         |
|-------------------|-----------------------------------------------------------------|
| `listen_addr`     | Address to listen on. Defaults to `127.0.0.1:8080`.             |
| `admin_key`       | API key accepted on admin endpoints, at least 32 bytes.         |
| `allowed_origins` | Browser origins allowed to read `GET /flags` cross-origin.      |

See `config.example.json` for a starting point.
