// Package archive is bookkeeping for the archive stage.
package archive

// Stage is the stage name reported in logs.
const Stage = "archive"

// Label returns the log label for the stage.
func Label() string { return "stage:" + Stage }
