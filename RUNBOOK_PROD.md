# OpenClaw Prod Runbook

This runbook documents the production flow for a single VPS with GitOps deploys.

## Topology

- Source of truth: this Git repository (`main`).
- CI/CD trigger: push or merge to `main`.
- Deploy executor: GitHub Actions (`.github/workflows/deploy.yml`).
- Runtime:
  - `openclaw.service` (single systemd supervisor)
  - `nginx` (public edge, optional)
  - `ufw` (ports 22/80/443 only)
- App paths:
  - `/opt/openclaw/repo` (git checkout on server)
  - `/opt/openclaw/releases/<release_id>`
  - `/opt/openclaw/current` (active symlink)
  - `/opt/openclaw/bin/deploy.sh`

## One-time Bootstrap (Server)

1. Create user and directories:

```bash
sudo useradd --system --create-home --home-dir /var/lib/openclaw --shell /usr/sbin/nologin openclaw || true
sudo mkdir -p /opt/openclaw/{bin,releases}
sudo mkdir -p /etc/openclaw
```

2. Prepare repo checkout and remote:

```bash
sudo git clone https://github.com/osipovgleb/clawbot.git /opt/openclaw/repo
```

3. Create env file with secrets:

```bash
sudo install -m 600 -o root -g root /dev/null /etc/openclaw/openclaw.env
```

4. Install service file:

```bash
sudo cp ops/openclaw.service /etc/systemd/system/openclaw.service
sudo systemctl daemon-reload
sudo systemctl enable openclaw.service
```

5. Permissions:

```bash
sudo chown -R openclaw:openclaw /opt/openclaw
```

## Daily Operations

- Status:

```bash
systemctl status --no-pager openclaw.service
```

- Restart:

```bash
systemctl restart openclaw.service
```

- Live logs:

```bash
journalctl -u openclaw.service -f
```

- Health check:

```bash
curl -fsS http://127.0.0.1:18789/healthz || curl -fsS http://127.0.0.1:18789/
```

- List releases:

```bash
/opt/openclaw/bin/deploy.sh list
```

- Rollback:

```bash
/opt/openclaw/bin/deploy.sh rollback <release_id>
```

## Git Sync with Upstream

Local workflow to pull updates from shared OpenClaw and keep your prod branch current:

```bash
git checkout main
git fetch upstream
git merge upstream/main
git push origin main
```

If conflicts appear, resolve locally and push again. Deploy starts automatically after push to `main`.

## Acceptance Checklist

1. `systemctl restart openclaw.service` runs without restart loops.
2. No `Port 18789 is already in use` errors in `journalctl`.
3. Exactly one active supervisor (`openclaw.service`).
4. Service user is non-root (`openclaw`).
5. Unit file has no plaintext secrets.
6. Reboot test passes (`systemctl is-enabled openclaw.service` and service auto-starts).
7. Gateway is loopback-only; public access goes through `nginx`.
