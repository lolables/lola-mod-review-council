// Package schedule is bookkeeping for the schedule stage.
package schedule

// Stage is the stage name reported in logs.
const Stage = "schedule"

// Label returns the log label for the stage.
func Label() string { return "stage:" + Stage }
