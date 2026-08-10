# SeaweedFS on Podman (systemd quadlet)

Boot-persistent SeaweedFS deployment (S3 API, Master, Volume, Filer, WebDAV,
Admin UI) running as a root-managed Podman quadlet service. No reverse proxy —
ports are published directly to the host.

## Files

| File                   | Purpose                                                        |
|------------------------|------------------------------------------------------------------|
| `seaweedfs.container`  | Podman Quadlet unit (used on Podman >= 4.4.0)                   |
| `seaweedfs.service`    | Standard systemd unit file (fallback for Podman < 4.4.0 / 3.x)   |
| `entrypoint.sh`        | Wires the injected secret env vars into `weed` CLI flags        |
| `install.sh`           | Idempotent setup script: auto-detects Quadlet vs systemd unit   |
| `uninstall.sh`         | Cleanup script: stops service, removes unit files, secrets & data|
| `rotate-credentials.sh`| Credential rotation script: regenerates secrets and restarts unit|

## Quick start

```bash
git clone <this-repo> seaweedfs-setup   # or copy the 4 files over
cd seaweedfs-setup
sudo ./install.sh
```

That's it — `install.sh` will:
1. Create `/srv/seaweedfs/data` (bind-mounted into the container)
2. Install `entrypoint.sh` to `/srv/seaweedfs/entrypoint.sh`
3. Generate Podman secrets for admin UI and S3 credentials (random passwords,
   skipped if they already exist — safe to re-run)
4. Detect Podman capability:
   - On Podman >= 4.4.0: installs Quadlet unit `/etc/containers/systemd/seaweedfs.container`
   - On Podman < 4.4.0 (e.g. Podman 3.4.4): installs standard systemd unit `/etc/systemd/system/seaweedfs.service`
5. `systemctl daemon-reload` + enables/restarts `seaweedfs.service`

## Ports

| Port  | Service         |
|-------|-----------------|
| 8333  | S3 API          |
| 9333  | Master UI       |
| 9340  | Volume server (gRPC/HTTP, not a UI) |
| 8888  | Filer UI        |
| 7333  | WebDAV          |
| 23646 | Admin UI        |

All six are published directly on the host — nothing sits behind a proxy in
this setup. If this box is reachable beyond your own machine, treat those
ports as you would any other admin surface (firewall rules, VPN-only access,
etc.).

## Credentials

Admin UI and S3 access/secret keys are generated as random strings during
`install.sh` and stored as **Podman secrets**, not as plaintext in the
quadlet file (which lives in `/etc` and is typically world-readable).

Retrieve them any time:

```bash
sudo podman secret inspect seaweedfs-admin-user --showsecret
sudo podman secret inspect seaweedfs-admin-pass --showsecret
sudo podman secret inspect seaweedfs-s3-key --showsecret
sudo podman secret inspect seaweedfs-s3-secret --showsecret
```

To rotate credentials automatically:

```bash
sudo ./rotate-credentials.sh             # rotates all generated credentials
sudo ./rotate-credentials.sh --admin-pass  # rotates only Admin UI password
sudo ./rotate-credentials.sh --s3-secret   # rotates only S3 secret key
```

## Data persistence

Container data lives in `/data` inside the container, bind-mounted from
`/srv/seaweedfs/data` on the host. This covers master metadata, volume
files, and filer metadata — all in one directory.

Back this directory up like any other stateful service data. There's no
snapshotting or replication configured here — this is a single-node setup.

## Operations

```bash
systemctl status seaweedfs.service
journalctl -u seaweedfs.service -f
sudo systemctl restart seaweedfs.service
sudo systemctl stop seaweedfs.service
```

After editing `seaweedfs.container`, always:

```bash
sudo systemctl daemon-reload
sudo systemctl restart seaweedfs.service
```

(Quadlet regenerates the actual systemd unit from the `.container` file at
`daemon-reload` time — restarting without reloading first will silently use
the stale config.)

## Uninstallation

To remove the service, Podman secrets, and Quadlet file while preserving `/srv/seaweedfs/data` (prompts for confirmation):

```bash
sudo ./uninstall.sh
```

To remove everything including **PERMANENTLY DELETING ALL PERSISTENT DATA** in `/srv/seaweedfs` (requires typing `YES` to confirm):

```bash
sudo ./uninstall.sh --purge
```

For non-interactive or automated scripts, pass `-y` / `--yes` to skip prompts:

```bash
sudo ./uninstall.sh --purge -y
```

## Known gaps / next steps

- **No TLS / reverse proxy** — everything is plain HTTP on the published
  ports. A Caddy (or nginx) front end was scoped out for now; revisit before
  this touches anything customer-facing.
- **Runs as root** — this uses the system-level (root) quadlet path. A
  rootless variant (running as a dedicated non-root user) was also scoped
  out for now; revisit if this needs to run with least privilege.
- **Single node** — no replication/erasure coding configured; fine for a
  lab/dev box, not for anything you can't afford to lose.
- **Image pinning** — `seaweedfs.container` uses `chrislusf/seaweedfs:latest`
  with `AutoUpdate=registry`. For anything beyond a lab, pin to a specific
  tag instead for reproducibility.
