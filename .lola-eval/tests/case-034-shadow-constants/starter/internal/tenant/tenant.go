// Package tenant is bookkeeping for the tenant stage.
package tenant

// Stage is the stage name reported in logs.
const Stage = "tenant"

// Label returns the log label for the stage.
func Label() string { return "stage:" + Stage }
