# SatuChain Validator Node Installer

Official installer for running a validator node on **SatuChain Mainnet** (Chain ID: 10111945).

## Requirements

Before running the installer, make sure you have:

1. **Register at the dashboard** → [staking.satuchain.com](https://staking.satuchain.com)
2. **Stake a minimum of 500,000 STU** via the dashboard
3. **Verify USDT payment** with the admin
4. **Receive your Validator Key** (`satu-val-...`) from the admin once all requirements are met

> The installer **will not run** without a valid Validator Key from the admin.

## Minimum Server Specifications

| Component | Minimum |
|-----------|---------|
| OS | Ubuntu 20.04 / 22.04 / Debian 11+ |
| CPU | 4 cores (x86_64) |
| RAM | 8 GB |
| Disk | 100 GB SSD |
| Network | Port 30303 TCP/UDP open |

## Installation

```bash
curl -fsSL https://raw.githubusercontent.com/satuchain/sdk/main/install-validator.sh | sudo bash
```

> **Recommended:** Download first, review the script, then run:

```bash
wget https://raw.githubusercontent.com/satuchain/sdk/main/install-validator.sh
# Review the script before running
less install-validator.sh
# Run
sudo bash install-validator.sh
```

## What the Installer Does

1. Check server specifications
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

SatuChain validator nodes run on **APOS** (Autonomous Proof-of-Stake), SatuChain's proprietary node software built and maintained by the SatuChain team. The node image is hosted on the SatuChain GitHub Container Registry and verified via checksum during installation.

- Node image: `ghcr.io/satuchain/node`
- Consensus: Proof of Authority / Proof of Stake (Clique + validator set)
- Engine: EVM-compatible

## Support

- Dashboard: [staking.satuchain.com](https://staking.satuchain.com)
- Explorer: [stuscan.com](https://stuscan.com)
- Chain ID: `10111945`
- Network: SatuChain Mainnet
