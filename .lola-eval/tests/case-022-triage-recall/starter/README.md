# ledger

A small append-only ledger service.

## Guarantees

Records are append-only. Once written, a record is never removed or
modified — corrections are recorded as new compensating entries.

## Running

    go run .

The service listens on :8080 and exposes `/health`.
