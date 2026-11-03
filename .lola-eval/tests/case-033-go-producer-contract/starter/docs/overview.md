# Overview

The runner takes a job spec, checks each step with the gate, and executes the
cleared steps in order. Steps may use the `archive`, `lint` and `notify`
binaries; the packages under `internal/` hold the runner's own bookkeeping for
each of them.
