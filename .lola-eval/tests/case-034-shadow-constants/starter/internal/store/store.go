// Package store is bookkeeping for the store stage.
package store

// Stage is the stage name reported in logs.
const Stage = "store"

// Label returns the log label for the stage.
func Label() string { return "stage:" + Stage }
