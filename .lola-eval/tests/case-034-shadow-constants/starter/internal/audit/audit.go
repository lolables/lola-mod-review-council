// Package audit is bookkeeping for the audit stage.
package audit

// Stage is the stage name reported in logs.
const Stage = "audit"

// Label returns the log label for the stage.
func Label() string { return "stage:" + Stage }
