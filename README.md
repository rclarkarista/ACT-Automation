# ACT + CVaaS Onboarding Helper 🤖

An automated **CVaaS onboarding tool** & **ACT lab creator** for EOS devices running in Arista Cloud Test (ACT). Point it at **your running lab** and every switch shows up in CVaaS Inventory ~1 minute later. *Code authored by Claude.*

## Why Does this exist? 🤷‍♂️

Using ACT with CVaaS can be painful for a few reasons: 

1. If you need to change a *single link* or add/remove a node, the entire lab must be **destroyed and recreated**. CVaaS knows devices by their serial & system MAC.
2. Automating a system that has ZTP configuration necessary to tie EOS devices to CVaaS must be re-deployed every time a topology change is made. Painful.

This script aims to solve those problems by assigning a static MAC & serial to every device (`generate.sh` script) and by automatically discovering, SSH-ing into and pasting the onboarding token into every EOS device to simplify new/existing devices showing up in CVaaS. 

## Quickstart 🏎️
> [!NOTE]
> This has been built & tested on a Mac, mileage may vary on PC.

### Create a new simple ACT Topology

1. Download or clone the repo to your laptop
2. Open a terminal and move to that directory
3. Run the `./generate.sh` script
4. Answer the prompts to build a simple topology you can use in ACT
5. Upload the generated topo file to ACT + deploy your topology in the ACT UI
6. Wait for Running state

```bash
./generate.sh
#   Serial prefix (e.g. bsmith): rclark
#   Hostname prefix [rclark]:
#   Number of spines [2]:
#   Number of leaves [4]:
#   Pair leaves into MLAG pairs (y/n) [n]:
#   EOS version [4.32.2F]:
#   Continue? [y/N] y
#   Wrote topology-rclark-2026-05-21.yml
```

### Once you created a lab (or you have one running) already

1. Collect an ACT API key from the ACT UI
   * Click your **Username** in the top right > **My Profile** > **API Key**
2. Collect an onboarding token from CVaaS
   * **Devices** > **Device Registration** > **Generate a Token**
3. Run the `./onboard.sh` script locally in a terminal
4. Follow the prompts 

```bash
./onboard.sh
#   ACT tenant [ce]:
#   ACT username (e.g. firstname.lastname): ryan.clark
#   ACT API key: ****  (36 chars)
#   CVaaS enrollment token: ****  (944 chars)
#   ...
#   Lab: rclark-campus-lab
#   EOS password: from local act-campus-topo-no-cvp_rclark.yml
#   Will paste TerminAttr config to 55 vEOS device(s):
#     ...
#   Continue? [y/N] y
#   Pre-flight: checking CVaaS reachability from each device...
#     ...
#   Pasting TerminAttr snippet to each switch...
#     ...
```

`onboard.sh` reads the EOS password out of the topology's `veos:` block
(checking your local file first, then the ACT API, then falling back to
`cvp123!`).

## How this works ⚙️

Two scripts, run in order:

| Step | Script | What it does |
| ---- | ------ | ------------ |
| 1 *(optional)* | `./generate.sh` | Interactively generates a topology YAML with **pinned `serial_number` + `system_mac_address`** on every node. Skip this step if you already have a topology — `onboard.sh` works with any vEOS topology, not just generated ones.  |
| 2 | `./onboard.sh` | Finds your Running lab via the ACT API and SSH-pastes the TerminAttr onboarding snippet to every vEOS switch. Auto-detects the EOS password from the topology's `veos:` block, so it works with topologies you authored elsewhere. |

Between the two (if you ran step 1): upload + deploy the generated
topology in the ACT UI.

No DHCP server. No ZTP. No bootstrap.py. No dedicated ztp-server node.

## Files 🗂️

| File | Purpose |
| ---- | ------- |
| `onboard.sh`  | Lists your Running labs and onboards every vEOS switch to CVaaS. |
| `generate.sh` | *(optional)* Interactive topology generator with pinned serials + MACs. Asks for a serial prefix; caches spine/leaf counts, MLAG choice, and EOS version. |
| `_common.sh`  | Shared helpers (prompt/cache/tool-check). Sourced by both scripts; don't run directly. |
| `topology-<prefix>-<YYYY-MM-DD>.yml` | Topology produced by `generate.sh`. Filename must be unique across the ACT tenant — `generate.sh` enforces the convention. |
| `.config`     | Auto-generated cache of your answers. **gitignored.** Delete to re-prompt. |

## Prerequisites

On your laptop:
- `bash`, `curl`, `jq`, `sshpass`. Install the non-defaults with:
  ```bash
  brew install jq hudochenkov/sshpass/sshpass
  # bash + curl ship with macOS
  ```
- (Optional) `graphviz` — if installed, `generate.sh` also emits a PNG
  diagram to upload with your topology file in ACT alongside the YAML:
  ```bash
  brew install graphviz
  ```

## Redeploying

When you want to change the topology:

1. Edit the topology — for `generate.sh`-produced ones, re-run it and
   change spine/leaf counts as needed (the new file has today's date in
   its name, so it won't overwrite your previous labs). For
   hand-authored topologies, edit in place.
2. Upload + deploy in the ACT UI. Either create a new lab or overwrite your existing.
3. Run `./onboard.sh` and pick the new lab from the list.

If the topology has pinned `serial_number` + `system_mac_address` on
every node (either via `generate.sh` or because you added them
manually), CVaaS will recognize the devices as the same ones from
before — state / dashboards / studios / labels carry over.

## Cleaning up CVaaS 🧹
Be respectul to others and clean up any orphaned VM's you have built and aim to retire. CVaaS actually has a nice bulk decommission feature. 

1. Click **Devices** > **Device Registration**
2. Click the **Decommission and Replace Devices** tab at the top
3. Click the **Hostname** chip and type in the hostname string you used
4. Click select all and click the **Decommission** button
   
![alt text](<cvaas-cleanup.gif>)

## Sharing this with someone else 🎁

1. Clone the repo.
2. Run `./onboard.sh` against any Running lab — they enter their own ACT
   and CVaaS creds when prompted. Works on labs they authored anywhere.
3. *(Optional)* Run `./generate.sh` if they want pinned-identity
   topologies of their own. It forces them to enter their own serial
   prefix (the `(e.g. bsmith)` hint means it's never cached or shared).

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
