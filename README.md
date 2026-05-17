# SatuChain Validator Node Installer

Official installer for running a validator node on **SatuChain Mainnet** (Chain ID: 10111945).

Current version: **v2.6.1** • [Releases](https://github.com/satuchain/node-installer/releases) • [Issues](https://github.com/satuchain/node-installer/issues)

## Quick Start

```bash
curl -fsSL https://staking.satuchain.com/install-validator.sh | sudo bash
```

If you hit the curl pipe error `bash: syntax error near unexpected token '('`, download first then run:

```bash
curl -fsSL https://staking.satuchain.com/install-validator.sh -o /tmp/sat.sh
sudo bash /tmp/sat.sh
```

## Requirements

Before running the installer:

1. **Register at the dashboard** → [staking.satuchain.com](https://staking.satuchain.com)
2. **Self-stake at least 2,000,000 STU** (or get **exempt** flag from admin) on SatuChain Mainnet
3. **Submit your server IP** via the dashboard → wait for admin to whitelist
4. **Receive your Validator Key** (`satu-val-...`) from the admin

> Installer will refuse to proceed without a valid, admin-issued key.

## Server Specifications

| Component | Minimum | Recommended |
|-----------|---------|-------------|
| OS        | Ubuntu 20.04 / 22.04 / Debian 11+ | Ubuntu 22.04 LTS |
| CPU       | 2 vCPU (x86_64) | 4 vCPU |
| RAM       | 2 GB + 2 GB swap | 4 GB |
| Disk      | 15 GB free | 100 GB SSD |
| Network   | Port **30303 TCP+UDP outbound and inbound** | 100 Mbps |
| Uptime    | > 90% | > 99% |

> **Critical:** Your VPS provider MUST allow **outbound port 30303** to `46.250.225.9` (bootnode). Some cheap shared-host plans silently block this. See [Troubleshooting → peer count stays 0](#peer-count-stays-0).

### Tested VPS Providers

| Provider | Plan | Notes |
|----------|------|-------|
| Hetzner | CPX21 (3 vCPU / 4 GB) — €6/mo | ✓ Liberal egress, recommended |
| Contabo | VPS S (4 vCPU / 8 GB) — $8.49/mo | ⚠ Some plans block outbound :30303 — verify before commit |
| Vultr | High Frequency (2 vCPU / 4 GB) — $24/mo | ✓ Global regions |
| IDCloudHost | Cloud VPS Pro — Rp 200K/mo | ✓ Indonesia regional, good for SE Asia |
| BizNet Gio | Cloud VM — Rp 250K/mo | ✓ Indonesia regional |

## Subcommands

| Command | Purpose |
|---------|---------|
| `sudo bash sat.sh` | Full install (first time) or resume an existing install |
| `sudo bash sat.sh --fix` | Re-run only network/peer diagnostics + auto-fix, no full reinstall |
| `sudo bash sat.sh --status` | Quick check: container running? block height? peer count? |
| `sudo bash sat.sh --backup` | Manual backup of keystore + state + config (~20 KB) |
| `sudo bash sat.sh --restore <file>` | Restore from a previous backup tarball |

## What the Installer Does

1. Spec check (CPU/RAM/disk) — auto-creates swap if RAM < 4 GB
2. Connectivity check (internet, staking API, bootnode P2P)
3. Validate your address + key against the staking API (security gate)
4. Install Docker if missing
5. Download + verify genesis block
6. Create encrypted keystore from your validator private key (or import existing JSON)
7. Configure UFW (SSH + 30303 only, everything else dropped)
8. Generate `docker-compose.yml` with safe geth flags (`--nat=extip:`, `stop_grace_period: 60s`)
9. Pull the node image and start the container in **sync mode** (no `--mine` yet)
10. Wait for admin to approve — once approved, restart in **validator mode** (`--mine`)
11. Set up `monitor.sh` cron + systemd timer (5-min heartbeat to dashboard)
12. Set up daily backup cron (02:00 UTC)
13. `verify_peering`: confirm peer count > 0, auto-register peer-helper if outbound :30303 blocked

## File Locations

```
/opt/satuchain-validator/
├── docker-compose.yml       # generated geth + image
├── monitor.sh               # cron / timer pushes heartbeat
├── backup.sh                # daily backup script
├── .state                   # validator address, key, public IP, etc. (chmod 600)
├── config/
│   ├── config.toml          # node config
│   ├── genesis.json
│   └── password.txt         # keystore password (chmod 600, owned 1000:1000)
├── keystore/
│   └── UTC--*               # encrypted private key
├── data/
│   └── geth/                # chaindata — DO NOT manually delete
├── backups/
│   └── validator-YYYYMMDD-HHMMSS.tar.gz    # keep last 7
└── logs/
    ├── monitor.log
    └── backup.log
```

## Troubleshooting

### Installer just exits silently right after "..." step

The installer runs `set -euo pipefail`. Any unhandled command failure exits. Pre-2.6 had a long sequence of these; if you're on **v2.5.0+ you should not hit these any more**. If you do:

```bash
# get the exact error
sudo bash -x /tmp/sat.sh 2>&1 | tail -50
```

### `bash: syntax error near unexpected token '('`

Caused by **pasting message text into the terminal** along with the command. Bash tries to parse the explanation as commands. Solution: download first then run, don't curl-pipe:

```bash
curl -fsSL https://staking.satuchain.com/install-validator.sh -o /tmp/sat.sh
sudo bash /tmp/sat.sh
```

### `IP not authorized` from validate-key

Your validator host's egress IP is not whitelisted. Either:

- Submit your IP via the dashboard "My Validator" page, OR
- Have admin run `POST /api/admin/whitelist-ip` with your IPv4

The installer forces `curl --ipv4` on every API call so an IPv6 outbound default won't surprise you any more (v2.4.3+).

### Peer count stays 0

This is the most common deep issue. Run:

```bash
sudo bash /tmp/sat.sh --fix
```

The fix subcommand will:

1. Re-resolve `bootnode.satuchain.com` → IP and rewrite `config.toml` if stale
2. Add `--nat=extip:<YOUR_PUBLIC_IP>` to `docker-compose.yml` if missing (without it, geth advertises 127.0.0.1 and peers can't dial back)
3. Re-apply UFW rules for 30303/tcp+udp
4. Test outbound TCP to bootnode
5. If after 90 s peer count is still 0, **auto-register with the peer-helper service** — core validators will dial out to your IP, bypassing any outbound egress filter on your VPS

If the diagnostic dump at the end says outbound 30303 is blocked, contact your VPS support and ask them to allow outbound TCP+UDP to `46.250.225.9:30303` (standard blockchain P2P).

### Dashboard shows offline / Last Check is hours old

Your `monitor.sh` cron is not running. Check:

```bash
sudo crontab -l | grep satuchain
sudo systemctl status satuchain-monitor.timer
sudo bash /opt/satuchain-validator/monitor.sh
tail -10 /opt/satuchain-validator/logs/monitor.log
```

If `crontab -l` is empty, the installer's `setup_monitor` step didn't finish — re-run the installer:

```bash
sudo bash /tmp/sat.sh
# resume Y
```

### `Fatal: Failed to unlock account ... permission denied` in geth logs

`password.txt` ownership/permissions wrong. v2.5.2+ fixes this automatically. If you're on older install:

```bash
sudo chown 1000:1000 /opt/satuchain-validator/config/password.txt
sudo chmod 600 /opt/satuchain-validator/config/password.txt
sudo chmod 755 /opt/satuchain-validator/config
sudo docker restart satuchain-validator
```

### `unauthorized validator` in geth logs (after admin approved on-chain)

Geth needs to sync past the block where `addValidator()` was executed before it knows it's allowed to sign. Just wait — depending on chain head this can be a few minutes. Watch:

```bash
docker exec satuchain-validator sh -c 'geth attach --datadir /data --exec "({block:eth.blockNumber,peers:net.peerCount})"'
```

If `block` is stuck at 0 or 1 for more than 5 minutes, your peer count is probably 0 — see [Peer count stays 0](#peer-count-stays-0).

### Container crash-loops with `cat: can't open /bsc/config/config.toml`

Old `docker-compose.yml` is missing `entrypoint: ["geth"]`. Re-run installer or `--fix` (v2.4.8+) to rewrite compose.

### Port 8545 conflict on start

Another geth (anvil, hardhat, ganache, an old crashed container) is holding it. The installer auto-cleans any `^geth ` process and removes any container named `satuchain-validator` before start (v2.5.0+). If the holder is non-geth (e.g. `anvil`), the installer aborts and tells you to free it manually.

## Backup & Recovery

Daily auto-backup runs at **02:00 UTC** (1 hour before the core val1-4 maintenance window). Backups are stored locally in `/opt/satuchain-validator/backups/` (keep last 7).

**What gets backed up** (~20 KB total):
- `keystore/UTC--*` (encrypted private key)
- `.state` (address, key, auto-password)
- `config/password.txt`, `config/config.toml`, `config/genesis.json`

**What does NOT get backed up:** `data/geth/chaindata/` (GBs, re-downloadable from peers via snap sync).

**Manual backup:**
```bash
sudo bash /tmp/sat.sh --backup
ls -la /opt/satuchain-validator/backups/
```

**Restoring on a new server** (zero downtime migration):

1. Stop validator on OLD server: `docker stop satuchain-validator` (let it finish writes — `stop_grace_period: 60s`)
2. Copy a recent backup tarball off the OLD server
3. On NEW server:
   ```bash
   sudo mkdir -p /opt/satuchain-validator
   curl -fsSL https://staking.satuchain.com/install-validator.sh -o /tmp/sat.sh
   sudo bash /tmp/sat.sh --restore /path/to/validator-YYYYMMDD-HHMMSS.tar.gz
   sudo bash /tmp/sat.sh   # full install — will resume with restored state
   ```
4. Update server IP in the dashboard (if changed)
5. Make sure to **shut down** OLD server before NEW one starts mining — running both simultaneously will double-sign and get slashed 5%

## Security Notes

- `keystore/UTC--*` files are encrypted with the password in `config/password.txt`. Both are required to use the validator key; treat them like seed phrase backups.
- The `.state` file may contain the auto-generated keystore password (when "Auto-generate" was chosen during install). It is `chmod 600 root:root`. Do not check it into version control or paste it into chat.
- The validator key (`satu-val-...`) is what proves ownership of your validator account to the dashboard API. Keep it secret. v2.5.5+ no longer returns the full key via the public `/api/my-key/:address` endpoint.
- The peer-helper service (v2.5.8+) enforces:
  - Enode IP must match registered server IP (IP-bind defense)
  - Source IP must match too (registration only from validator host)
  - Pubkey is TOFU-locked after first registration (admin must clear to rotate)
  - Entries auto-expire after 7 days

## Node Software

- Image: `ghcr.io/satuchain/node:1.7.2` (public, MIT licensed binary)
- Consensus: **APoS** (Adaptive Proof-of-Stake), SatuChain fork of BSC Parlia
- Engine: EVM-compatible
- Chain ID: `10111945`
- Source: <https://github.com/satuchain/sdk>

## Links

- Dashboard: [staking.satuchain.com](https://staking.satuchain.com)
- Explorer: [stuscan.com](https://stuscan.com)
- Releases: <https://github.com/satuchain/node-installer/releases>

---

© SatuChain.
