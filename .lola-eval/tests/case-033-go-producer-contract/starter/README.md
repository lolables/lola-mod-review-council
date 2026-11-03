# gate

A small job runner. A job spec lists the steps to run; the runner checks
every step against an allowlist of binaries before it executes anything.

- `gate run FILE` loads a spec and prints the steps the gate clears,
  stopping at the first step it denies.
- `gate new NAME` writes a starter spec for a new job.

`Validate` allows only the binaries in `allowed` and refuses command
substitution.
