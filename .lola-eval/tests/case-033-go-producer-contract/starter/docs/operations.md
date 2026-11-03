# Operations

Job output lands in the directory named by the runner's `OUT_DIR` setting, which
`internal/envx` resolves from the environment when the config file is loaded.
Archive the output after the job finishes and notify the ops channel on failure.
