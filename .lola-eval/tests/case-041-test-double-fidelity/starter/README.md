# accounts

Small account store. `Store` is the persistence interface; `FileStore` is
the production implementation, backed by a JSON file.

Contract every `Store` honours:

- A cancelled or expired context fails the call with `ctx.Err()` and
  changes nothing.
- Emails are unique, compared case-insensitively after trimming.
  `Create` of a taken email returns `ErrDuplicate`.
- `Get` of an unknown email returns `ErrNotFound`.
