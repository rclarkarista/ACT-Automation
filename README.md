# ACT + CVaaS onboarding helper

A small, shareable toolkit for spinning up an Arista Cloud Test (ACT) lab and
onboarding its vEOS switches to CloudVision as a Service (CVaaS) — so the
same devices keep the same identity in CVaaS across topology redeploys.

Two scripts, run in order:

| Step | Script | What it does |
| ---- | ------ | ------------ |
| 1    | `./generate.sh` | Interactively generates a topology YAML with pinned serials + MACs. |
| 2    | `./onboard.sh`  | Finds your Running lab via the ACT API and SSH-pastes the TerminAttr onboarding snippet to every vEOS switch. |

Between the two: upload + deploy the generated topology in the ACT UI.

## How it works

1. `generate.sh` writes a topology where every switch has a stable
   `serial_number` and `system_mac_address`. CVaaS identifies devices by
   serial, so the same topology always produces the same set of devices in
   CVaaS — even after you redeploy.
2. You upload + deploy the topology in the ACT UI.
3. `onboard.sh` queries the ACT API for your Running labs, lets you pick
   one if there's more than one, and SSH-pastes the TerminAttr onboarding
   snippet (with your CVaaS token inlined) to every vEOS device in that
   lab. They appear in CVaaS Inventory within ~1 minute.

No DHCP server. No ZTP. No bootstrap.py. No dedicated ztp-server node.

## Files

| File | Purpose |
| ---- | ------- |
| `generate.sh` | Interactive topology generator. Always asks for a serial prefix; caches spine/leaf counts + EOS version. |
| `onboard.sh`  | Lists your Running labs and onboards every vEOS switch to CVaaS. |
| `_common.sh`  | Shared helpers (prompt/cache/tool-check). Sourced by both scripts; don't run directly. |
| `topology-<prefix>-<YYYY-MM-DD>.yml` | Generated topology. Filename must be unique across the ACT tenant — `generate.sh` enforces the convention. |
| `.config`     | Auto-generated cache of your answers. **gitignored.** Delete to re-prompt. |

## Prerequisites

On your laptop:
- `bash`, `curl`, `jq`, `sshpass`. Install the non-defaults with:
  ```bash
  brew install jq hudochenkov/sshpass/sshpass
  # bash + curl ship with macOS
  ```

In ACT:
- Permission to upload + deploy a topology.
- Your **ACT username** (e.g. `firstname.lastname`).
- An **ACT API key** from your ACT user profile.

In CVaaS:
- An **enrollment token** from `Devices → Inventory → Add Devices →
  Onboard with Token`. Single reusable token is fine — it works for every
  device in the topology.

## Quickstart

```bash
# 1. Generate a topology.
./generate.sh
#   Serial prefix (e.g. bsmith): rclark
#   Number of spines [2]:
#   Number of leaves [4]:
#   EOS version [4.32.2F]:
#   Continue? [y/N] y
#   Wrote topology-rclark-2026-05-21.yml

# 2. Upload + deploy that file via the ACT UI. Wait for the lab to reach Running.

# 3. Onboard every switch to CVaaS.
./onboard.sh
#   ACT tenant [ce]:
#   ACT username (e.g. firstname.lastname): ryan.clark
#   ACT API key: ****  (36 chars)
#   CVaaS enrollment token: ****  (944 chars)
#   ...
#   Lab: rclark-claude-test
#   Will paste TerminAttr config to 6 vEOS device(s):
#     spine1        10.18.131.218
#     ...
#   Continue? [y/N] y
#   Pasting TerminAttr snippet to each switch...
#     spine1        10.18.131.218     ok
#     ...

# 4. Watch CVaaS -> Inventory. Devices appear under their pinned serials
#    (rclark-spine1, rclark-leaf1, ...) within ~1 minute each.
```

## Redeploying

When you want to change the topology:

1. Re-run `./generate.sh` — bump spine/leaf counts as needed. The new file
   has today's date in its name, so it won't collide with previous uploads.
2. Upload + deploy in the ACT UI. (Leave the old lab undeployed/deleted to
   avoid duplicates.)
3. Run `./onboard.sh` and pick the new lab from the list.

Because the serials are pinned to the prefix, CVaaS recognizes the devices
as the same ones from before. State / dashboards / studios / labels all
carry over.

## Sharing this with a coworker

1. Clone the repo.
2. Run `./generate.sh` — it forces them to enter their own serial prefix
   (the `(e.g. bsmith)` hint means it's never cached or shared).
3. Run `./onboard.sh` — they enter their own ACT and CVaaS creds when
   prompted.

No edits to either script needed.

## Why TerminAttr token-secure auth instead of the bootstrap.py flow

CVaaS supports two onboarding paths:

- **`bootstrap.py`**: an Arista-provided Python script that does a
  multi-step enrollment dance (token → device cert exchange → device-specific
  bootstrap → registration). Requires the device to be reachable to a
  bootstrap-script host during ZTP.
- **TerminAttr `token-secure` auth**: TerminAttr does the same enrollment
  internally on first connect, using just the enrollment token in a file.
  No ZTP, no DHCP, no HTTP server, no per-device bootstrap host — you just
  give the daemon a token and a CVaaS endpoint and it figures it out.

For an ACT lab where you have SSH access to every device the moment it
boots, the second path is dramatically simpler.

## v2 / TODO

- Drive ACT topology deploy / undeploy from the API directly (in progress
  with a coworker's Python tooling) — would collapse steps 2 and 3 above.
- Auto-generate the topology file from AVD configs (see
  [emilarista/act_topgen](https://github.com/emilarista/act_topgen)).
- Parallelize the auto-paste ssh loop (currently serial — fine for ~6
  switches, slow for larger topologies).
