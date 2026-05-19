# ACT + CVaaS bootstrap automation

A small, shareable workflow for spinning up an Arista Cloud Test (ACT) lab and
auto-registering its vEOS switches with CloudVision as a Service (CVaaS) — so
the same devices keep the same identity in CVaaS across topology redeploys.

## What it does

1. You deploy an ACT topology (`topology.yml`) that pins every vEOS to a stable
   `serial_number` and `system_mac_address`, with `ztp: true`.
2. You run `bootstrap.sh` on your laptop. It:
   - Prompts once for your CVaaS URL, CVaaS enrollment token, ztp-server IP,
     and a unique serial-number prefix (cached in `.config`).
   - Renders `bootstrap/bootstrap.py.template` with your token.
   - SCPs the rendered `bootstrap.py` to the lab's `ztp-server` (a generic
     Ubuntu node) and runs `setup-ztp-server.sh` there.
3. `setup-ztp-server.sh` installs `dnsmasq` (DHCP with option 67 pointing at
   the bootstrap URL) and a Python HTTP server hosting `bootstrap.py`.
4. The vEOS switches boot in ZTP mode, DHCP from `ztp-server`, fetch
   `bootstrap.py`, and complete the CVaaS enrollment handshake. Because their
   serial numbers are pinned in `topology.yml`, they appear in CVaaS with the
   same identity every time.

## Files

| File | Purpose |
| ---- | ------- |
| `topology.yml` | ACT topology — 2 spine, 4 leaf, 1 ZTP server. Edit the `rclark-` prefix to your own. |
| `bootstrap.sh` | The thing you run. Prompts, caches, renders, deploys. |
| `bootstrap/bootstrap.py.template` | Arista's official CVaaS bootstrap script, with `__CVAAS_URL__` / `__CVAAS_TOKEN__` placeholders. |
| `bootstrap/setup-ztp-server.sh` | Runs on the ztp-server. Installs dnsmasq + http server. |
| `.config` | Auto-generated cache of your answers. **gitignored.** Delete to re-prompt. |

## Prerequisites

On your laptop:
- `bash`, `ssh`, `scp`, `sshpass` (`brew install hudochenkov/sshpass/sshpass`)

In CVaaS:
- An **enrollment token** from `Devices → Inventory → Add Devices →
  Onboard with Token`. Single reusable token is fine.

In ACT:
- Permission to deploy a topology. (Manual via UI for now; API integration
  is planned for v2.)

## Quickstart

```bash
# 1. Edit topology.yml: change "rclark-" everywhere to your own unique prefix.
#    (The script will warn you if you forget.)

# 2. Deploy the topology in the ACT UI. Note the ztp-server's mgmt IP
#    (should be 192.168.0.5 as defined in topology.yml).

# 3. Run the bootstrap:
./bootstrap.sh

# First run will prompt for:
#   CVaaS URL              e.g. www.arista.io
#   CVaaS enrollment token (hidden input)
#   ztp-server IP          192.168.0.5
#   Serial-number prefix   e.g. rclark

# 4. Watch CVaaS → Inventory. Devices will appear under your prefixed
#    serial numbers (rclark-spine1, rclark-leaf1, ...).
```

## Redeploying

When you change `topology.yml` and redeploy the lab, the switches come up
clean — but because the serial numbers are pinned, CVaaS recognizes them as
the same devices. Just rerun `./bootstrap.sh` (it will reuse the cached
config, so you won't be prompted again).

## Sharing this with a coworker

1. They clone the repo.
2. They edit `topology.yml` and change the `rclark-` prefix to their own.
3. They run `./bootstrap.sh` and paste in their own CVaaS token.

No edits to the bootstrap scripts needed.

## v2 / TODO

- Drive ACT topology deploy / undeploy from the API directly (in progress
  with a coworker's Python tooling).
- Optional: auto-generate `topology.yml` from AVD configs (see
  [emilarista/act_topgen](https://github.com/emilarista/act_topgen)).
