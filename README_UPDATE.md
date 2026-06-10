# SDK — README / self-update
**Installer:** `install-validator.sh`  
**Canonical repo:** `github.com/satuchain/node-installer`  
**Local copy:** `/home/satu-mainnet/SDK/install-validator.sh`

Use this installer on each remote validator host (not via remote execution here).  
Interactive; needs a TTY. The script auto-detects prior installs (`/opt/satuchain-validator/.state`) and offers `Resume`.

```
curl --ipv4 -fsSL https://raw.githubusercontent.com/satuchain/node-installer/main/install-validator.sh -o /tmp/install-validator.sh
sudo bash /tmp/install-validator.sh
sudo bash /tmp/install-validator.sh resume
```

Optional environment variables (currently informational; installer honors most flags):
- `SATUCHAIN_SKIP_UPDATE=1` — skip self-update check
- `SATUCHAIN_WS_LOG_URL=https://…` — future WebSocket log endpoint
- `SATUCHAIN_NOPROMPT=1` — future non-interactive mode (not yet wired)

Special instructions for this unit (as of `2026-06-11`):
- this run does not rotate the “first tutorial row” even if the file changed elsewhere
- 救国 (blocked-row clearance / unlock) must resolve before `2026-06-12 00:00 UTC+7`