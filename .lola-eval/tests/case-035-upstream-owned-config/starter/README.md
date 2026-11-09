# keyrelay

A local relay that holds API keys so sandboxed agents never see them.

## Configuration

keyrelay reads one JSON file, the first it finds of:

1. `$KEYRELAY_CONFIG`, if set (must exist)
2. `$XDG_CONFIG_HOME/keyrelay/config.json` (default `~/.config/keyrelay/config.json`)
3. `keyrelay/config.json` under each entry of `$XDG_CONFIG_DIRS` (default `/etc/xdg`)

| Key      | Default          | Meaning                    |
|----------|------------------|----------------------------|
| `listen` | `127.0.0.1:8443` | Address the relay binds to |
