# SatuChain Validator Node Installer

Official installer for running a validator node on **SatuChain Mainnet** (Chain ID: 10111945).

## Requirements

Before running the installer, make sure you have:

1. **Register at the dashboard** → [staking.satuchain.com](https://staking.satuchain.com)
2. **Stake a minimum of 500,000 STU** via the dashboard
3. **Verify USDT payment** with the admin
4. **Receive your Validator Key** (`satu-val-...`) from the admin once all requirements are met

> The installer **will not run** without a valid Validator Key from the admin.

## Server Specifications

| Component | Minimum | Recommended |
|-----------|---------|-------------|
| OS | Ubuntu 20.04 / 22.04 / Debian 11+ | Ubuntu 22.04 LTS |
| CPU | 2 vCPU (x86_64) | 4 vCPU |
| RAM | 2 GB (+ 2 GB swap) | 4 GB |
| Disk | 50 GB SSD | 100 GB SSD |
| Network | 10 Mbps, Port 30303 TCP/UDP open | 100 Mbps |
| Uptime | > 90% | > 99% |

> **Note:** If your server has less than 2 GB RAM, the installer will offer to automatically create a swap file. Validators with extended downtime (> 10%) or double-signing will be slashed 5% and jailed for 7 days.

### Recommended VPS Providers

| Provider | Plan | Spec | Price |
|----------|------|------|-------|
| Hetzner | CPX21 | 3 vCPU / 4 GB / 80 GB | ~€6/mo |
| DigitalOcean | Basic | 2 vCPU / 2 GB / 60 GB | ~$18/mo |
| Contabo | VPS S | 4 vCPU / 4 GB / 100 GB | ~$7/mo |

## Installation

```bash
curl -fsSL https://raw.githubusercontent.com/satuchain/node-installer/main/install-validator.sh | sudo bash
```

> **Recommended:** Download first, review the script, then run:

```bash
wget https://raw.githubusercontent.com/satuchain/node-installer/main/install-validator.sh
# Review the script before running
less install-validator.sh
# Run
sudo bash install-validator.sh
```

## What the Installer Does

1. Check server specifications (CPU, RAM, disk) — with clear error messages and auto swap setup
2. Check network connectivity
3. **Validate requirements & Validator Key** with the SatuChain server (must be valid)
4. Install Docker (automatically if not present)
5. Download & initialize the genesis block
6. Import validator account (private key or keystore file)
7. Configure firewall
8. Run the node via Docker
9. Setup automatic monitor (sends status to dashboard every 5 minutes)

## After Installation

The node will automatically sync with the SatuChain network. Once fully synced, the dashboard will notify the admin for **Final Approval**.

```bash
# Check container status
docker ps --filter name=satuchain-validator

# View live logs
docker logs satuchain-validator -f

# Restart node
docker compose -f /opt/satuchain-validator/docker-compose.yml restart

# View monitor log
tail -f /opt/satuchain-validator/logs/monitor.log
```

## File Locations

```
/opt/satuchain-validator/
├── docker-compose.yml   # Docker configuration
├── monitor.sh           # monitor script (cron every 5 minutes)
├── .state               # install state (address, key, etc.)
├── config/
│   ├── config.toml      # node configuration
│   ├── genesis.json     # genesis block
│   └── password.txt     # keystore password
├── data/
│   ├── keystore/        # validator account
│   └── geth/            # blockchain data
└── logs/
    ├── geth.log         # node log
    └── monitor.log      # monitor log
```

## Node Software

SatuChain validator nodes run on **APoS** (Adaptive Proof-of-Stake), SatuChain's proprietary consensus built and maintained by the SatuChain team. The node image is hosted on the SatuChain GitHub Container Registry and verified via checksum during installation.

- Node image: `ghcr.io/satuchain/node`
- Consensus: APoS (Adaptive Proof-of-Stake)
- Engine: EVM-compatible (Chain ID: 10111945)

## Links

- Dashboard: [staking.satuchain.com](https://staking.satuchain.com)
- Explorer: [stuscan.com](https://stuscan.com)
- Chain ID: `10111945`
- Network: SatuChain Mainnet

---

© SatuChain. All rights reserved.
