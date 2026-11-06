// Package retry is bookkeeping for the retry stage.
package retry

// Stage is the stage name reported in logs.
const Stage = "retry"

// Label returns the log label for the stage.
func Label() string { return "stage:" + Stage }
