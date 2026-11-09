// Package notify is bookkeeping for the notify stage.
package notify

// Stage is the stage name reported in logs.
const Stage = "notify"

// Label returns the log label for the stage.
func Label() string { return "stage:" + Stage }
