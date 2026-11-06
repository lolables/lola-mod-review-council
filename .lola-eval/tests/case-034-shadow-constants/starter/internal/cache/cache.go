// Package cache is bookkeeping for the cache stage.
package cache

// Stage is the stage name reported in logs.
const Stage = "cache"

// Label returns the log label for the stage.
func Label() string { return "stage:" + Stage }
