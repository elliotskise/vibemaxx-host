# vibemaxx-host

One-line installer for the **VibeMaxx host daemon** — run your agent/terminal sessions on an
always-on VPS so they survive your local machine sleeping or shutting off. Your VibeMaxx desktop
app connects to the host over WebSocket ("Connected mode").

This repo contains **only the installer**. The daemon itself ships as the public
[`vibemaxx-host`](https://www.npmjs.com/package/vibemaxx-host) npm package; the script installs
it and wires up a hardened systemd service.

## Install

On a fresh **Debian/Ubuntu** VPS, as root:

```bash
# Loopback only — reach it over an SSH tunnel (simplest, most secure for personal use):
curl -fsSL https://raw.githubusercontent.com/elliotskise/vibemaxx-host/main/install.sh | sudo bash

# Public, with automatic TLS — point your domain's DNS at this box FIRST:
curl -fsSL https://raw.githubusercontent.com/elliotskise/vibemaxx-host/main/install.sh \
  | sudo bash -s -- --domain host.example.com
```

The script prints the **connect URL + token** at the end. Paste them into the desktop app under
**Settings → Connections → Host connection**.

### If you went loopback-only

Open an SSH tunnel from your laptop, then connect the app to the local end:

```bash
ssh -N -L 8765:127.0.0.1:8765 <user>@<your-vps>
# app → URL: ws://127.0.0.1:8765   Token: (printed by the installer)
```

## What it does

1. Installs Node.js 20 + build tools (if missing).
2. Creates a dedicated **non-root** `vibemaxx` user and a `~/projects` working dir.
3. `npm install -g vibemaxx-host` (native modules built for the box's Node ABI).
4. Generates a bearer token into `/etc/vibemaxx/host.env` (mode 0600), reused on re-runs.
5. Installs a **hardened** systemd unit (loopback-bound, `ProtectSystem=strict`,
   `ProtectHome=read-only`, `NoNewPrivileges`) and starts it.
6. With `--domain`, installs Caddy for automatic-TLS `wss://`.

It is **idempotent** — re-run it to update to the latest daemon; the token is preserved.

## Options

| Flag | Description |
| --- | --- |
| `--domain <host>` | Domain pointed at this VPS; installs Caddy for automatic-TLS `wss://`. |
| `--github-token <tok>` | GitHub token for authenticated git push/pull from the host. |
| `--token <tok>` | Use this bearer token instead of generating one. |
| `--port <n>` | Loopback port (default `8765`). |
| `--user <name>` | Service user (default `vibemaxx`). |
| `--version <spec>` | npm version/tag to install (default `latest`). |
| `--uninstall` | Stop + remove the service (user-data kept). |
| `--purge` | With `--uninstall`, also delete the data dir + env file. |

## Operate

```bash
journalctl -u vibemaxx-host -f      # live logs
systemctl status vibemaxx-host      # is it up?
systemctl restart vibemaxx-host     # restart
curl http://127.0.0.1:8765/healthz  # -> ok
```

## Security — read before exposing publicly

The daemon can **spawn arbitrary processes and read/write files** as the `vibemaxx` user — a
leaked token is a shell on your VPS. Treat the token like an SSH key. Never expose plaintext
`ws://` to the internet: use the SSH tunnel or the `--domain` TLS path. The service runs non-root
with systemd hardening, but that is *containment*, not a sandbox; ideally run it on a box with
limited egress.

## License

MIT — see [LICENSE](LICENSE).
