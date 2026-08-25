# oai-o1-adapter O-Cloud deployment

Helm chart, build automation and integration documentation for running the
**OAI O1-Adapter** on a Kubernetes O-Cloud, so that an OAI gNB can be managed by
an O-RAN / ONAP-based SMO over the **O1 interface**.

---

## Purpose

An OAI gNB has no O1 interface of its own. Its management surface is a **telnet
shell** exposed by the softmodem's `o1` telnet module — useful for a human on
the RAN host, but not something an SMO can mount, subscribe to, or collect
performance files from. An SMO expects standardised O1: NETCONF/YANG for
configuration and fault management, VES events for registration and alarms, and
3GPP XML performance files delivered over SFTP.

The **OAI O1-Adapter** closes that gap. It is a telnet-to-NETCONF/VES bridge
that presents the gNB to the SMO as a standards-compliant managed element:

- **Southbound** it opens a telnet session to the gNB and issues `o1 stats` once
  per second, parsing the returned JSON into a YANG datastore.
- **Northbound (CM/FM)** it serves the 3GPP NRM tree (`gNBDUFunction`,
  `NRCellDU`, …) over NETCONF, and pushes faults to the SMO as VES events.
- **Northbound (PM)** it writes 3GPP measurement XML files and announces them
  with a VES `fileReady`, so the SMO's data-file collector pulls them by SFTP.
- **Registration** it sends a VES `pnfRegistration` at startup and periodic
  heartbeats thereafter.

The whole NETCONF stack is bundled in **one container** — `netopeer2-server`,
`sysrepo`, the installed 3GPP and IETF YANG models, and the `gnb-adapter` binary
— so no separate NETCONF server is deployed alongside it. One adapter pod is the
complete O1 endpoint the SMO mounts.

This repository is the **deployment and build layer** around that adapter. It
does not contain the adapter's source code — that lives
[upstream at EURECOM](https://gitlab.eurecom.fr/oai/o1-adapter). What is here:

1. A **Helm chart** that runs the adapter as its own Deployment on the O-Cloud,
   renders its `config.json` from values, and exposes NETCONF and SFTP to the
   SMO through a LoadBalancer or NodePort service.
2. **Two deployment profiles** — a monolithic gNB and a CU/DU split (where the
   adapter attaches to the DU) — that can run side by side on one cluster.
3. **Build scripts** that produce the adapter image and, critically, a **patched
   O1-capable gNB image**: the stock OAI FHI 7.2 runtime image ships without
   `libtelnetsrv_o1.so`, so the O1 telnet module cannot load and the adapter has
   nothing to talk to.
4. **Documentation** capturing the full integration against a real testbed —
   topology, addressing decisions, verification steps and the failure modes hit
   along the way.

---

## System architecture

![OAI O1-Adapter on a StarlingX O-Cloud](<resources/OAI o1 adapter Ocloud.jpg>)

The diagram shows where this chart sits in an end-to-end O-RAN deployment, from
the SMO down to the UE.

**SMO layer (top).** The management and orchestration domain. `rApp` consumes
RAN data and drives policy; `InfluxDB` stores the time-series performance data
collected from the RAN. Everything they need from the gNB arrives over **O1**.

**O1 interface (the vertical link).** The standardised management interface —
NETCONF/YANG for configuration and fault management, VES for events, SFTP for
performance files. This is the interface the adapter provides, and the one this
chart's Service exposes. `smo.advertisedHost` and `smo.netconfPort` in the
values files are exactly this link's address: the SMO's NETCONF client dials
*back into them* to mount the node, so they must be routable from the SMO
subnet.

**O-Cloud (StarlingX).** The Kubernetes infrastructure hosting the RAN
workloads. Two workloads matter here:

- **OAI O1-adapter** — deployed by this chart, as its **own pod**, not as a
  sidecar of the gNB. The gNB pod runs at Guaranteed QoS with static CPU pinning
  for NUMA locality; QoS is a per-pod property, so adding an adapter container
  to it would drop the whole pod out of Guaranteed and break the DU's core
  isolation. The adapter needs no radio cores — it is a ~1 Hz telnet poller — so
  it shares the node as an ordinary Burstable pod.
- **O-CU/O-DU** — the OpenAirInterface gNB, either monolithic or CU/DU-split.
  The adapter reaches it over telnet on `:9090` using the gNB management
  service's ClusterIP DNS name, which survives gNB pod restarts and IP changes.
  In a split deployment the adapter attaches to the **DU**, because that is
  where the O1-relevant state (`NRCellDU`, BWP, connected UEs) lives.

**FHI split 7.2 (M-Plane / CUS-Plane).** The fronthaul between the DU and the
radio unit. The **M-Plane** manages the RU; the **CUS-Plane** carries control,
user and synchronisation traffic. This is the fronthaul profile the gNB image is
built for — hence the `Dockerfile.gNB.fhi72.ubuntu` patching in the build
script.

**RU and UE (bottom).** The radio unit terminates the fronthaul and serves the
UE over the **Uu** air interface.

Read left-to-right in operational terms: UE traffic and cell state surface in
the DU, the adapter polls that state over telnet, translates it into YANG and
VES, and the SMO consumes it over O1 — with performance data landing in InfluxDB
for the rApp to act on.

For the concrete testbed instance of this architecture — node names, IP
addressing, mermaid data-path and message-sequence diagrams — see
[Integration with SMO](<docs/integration with SMO.md>).

---

## Project structure

```text
.
├── Chart.yaml                  Chart metadata: name, version, appVersion 2026.w30
├── values-mono.yaml            Profile — monolithic gNB      (LB .106, node-id oai-gnb-mono)
├── values-cudu.yaml            Profile — CU/DU split → DU    (LB .107, node-id oai-gnb-du)
├── templates/
│   ├── _helpers.tpl            Name and label helpers (fullname = <release>-oai-o1-adapter)
│   ├── configmap.yaml          Renders /adapter/config/config.json from values
│   ├── deployment.yaml         Adapter pod: ports 830/22, probes, config + /ftp mounts
│   ├── service.yaml            Northbound NETCONF/SFTP exposure (LoadBalancer or NodePort)
│   ├── pvc.yaml                Optional PM file storage, gated on pmStorage.enabled
│   └── NOTES.txt               Post-install wiring summary and verification commands
├── scripts/
│   ├── native_build.sh         Host build of the adapter (no Docker)
│   └── docker_ci_build.sh      Adapter image + patched O1-capable gNB image
├── docs/
│   ├── integration with SMO.md                             End-to-end integration guide
│   ├── OAI gNB with o1 and O1-adapter build procedure.md   Build reference
│   └── InfluxDB integration.md                             Placeholder — empty
└── resources/                  Architecture diagrams (.jpg / .png)
```

### How the pieces relate

The repository has three layers that are used in order — **build**,
**configure**, **deploy**:

**1. Build (`scripts/`)** produces the two images the deployment needs.
`docker_ci_build.sh` builds the adapter image from the upstream Dockerfile, then
patches a sibling `openairinterface5g/` checkout so the gNB runtime image
carries `libtelnetsrv.so`, `libtelnetsrv_ci.so` and `libtelnetsrv_o1.so`, with a
hard-fail check if the O1 library is missing. `native_build.sh` is the
alternative path for running the adapter directly on a host — it installs the
NETCONF dependency chain, the YANG models and compiles the binary. Neither
script is invoked by Helm; they are prerequisites you run once per image
version, and their output tag is what you put in `image.tag`.

**2. Configure (`values-*.yaml` → `templates/configmap.yaml`)** is where all
per-deployment decisions live. The two profiles differ in exactly the fields
that must not collide between two adapters on one cluster — LoadBalancer IP,
advertised host, `info.nodeId` — plus the telnet target (gNB management service
vs. DU management service). Everything in a profile flows into the ConfigMap,
which renders the adapter's `config.json`; the Deployment mounts that file at
`/adapter/config/config.json` and carries its checksum as a pod annotation, so
editing a value and running `helm upgrade` rolls the pod automatically.

**3. Deploy (`templates/`)** turns the rendered config into running objects. The
Deployment is the adapter pod, pinned to the radio node via `nodeSelector` and
tolerating its taint. The Service publishes 830 and 22 outward on the ports the
SMO was told to use. The PVC only exists when `pmStorage.enabled` is true;
otherwise PM files live in an `emptyDir` and are lost on restart. `NOTES.txt`
prints the resulting wiring back to you at install time, which is the fastest
way to catch an address that does not match what the SMO expects.

**4. Reference (`docs/`, `resources/`)** — the guides carry the reasoning and
the real captured output behind the values in this chart. Start with
*Integration with SMO* for deployment and troubleshooting, and the *build
procedure* when you need to reproduce or modify the images.

There is **no default `values.yaml`** — a profile file is required on every
`helm` invocation. `helm template .` without `-f` fails by design.

---

## Prerequisites

- A Kubernetes O-Cloud namespace (the profiles use `ravi-ns`).
- An **O1-capable gNB image** — the FHI 7.2 runtime image must contain
  `libtelnetsrv_o1.so`. Stock images do not; use `scripts/docker_ci_build.sh`
  or follow [the build procedure](<docs/OAI gNB with o1 and O1-adapter build procedure.md>).
- The gNB started with the O1 telnet module:
  ```text
  --telnetsrv --telnetsrv.shrmod o1 --telnetsrv.listenport 9090
  ```
- A telnet Service in front of the gNB with live endpoints on `:9090`
  (the profiles dial its ClusterIP DNS name, not a NodePort).
- A LoadBalancer IP (MetalLB) that is **routable from the SMO subnet**, bound on
  the target node's O1 interface.
- An SMO exposing a VES collector and a NETCONF/SDNC client.

---

## Quick start

Build the images (adapter + patched gNB):

```bash
./scripts/docker_ci_build.sh
```

Set `REGISTRY`, `TAG` and `GNB_TAG` at the top of the script, then push both
images and set `image.repository` / `image.tag` in your values file.

Deploy the adapter against a monolithic gNB:

```bash
helm install o1-mono . -n ravi-ns -f values-mono.yaml
```

Or against a CU/DU-split gNB (adapter attaches to the **DU**):

```bash
helm install o1-cudu . -n ravi-ns -f values-cudu.yaml
```

Upgrade after editing a values file:

```bash
helm upgrade o1-mono . -n ravi-ns -f values-mono.yaml
```

The ConfigMap is checksummed into the pod template, so a config change rolls the
pod automatically.

---

## What gets deployed

| Object | Purpose |
| --- | --- |
| `Deployment` | One adapter pod; container ports 830 (NETCONF) and 22 (SFTP); TCP readiness/liveness probes on 830; `TERM=xterm-256color` for the bundled telnet client |
| `Service` | Exposes NETCONF and SFTP northbound — `LoadBalancer` (ports from `smo.*`) or `NodePort` (`smo.*` used as node ports) |
| `ConfigMap` | Renders `/adapter/config/config.json` from values |
| `PersistentVolumeClaim` | PM file storage at `/ftp`, only when `pmStorage.enabled=true`; otherwise `emptyDir` |

---

## Configuration

All values are rendered into `config.json`; the keys below are the ones that
matter operationally.

### Northbound — how the SMO reaches the adapter

| Key | Meaning |
| --- | --- |
| `smo.advertisedHost` | **Required.** Written to `network.host` and announced in pnfRegistration. SDNC dials *back into this address*, so it must be routable from the SMO. |
| `smo.netconfPort` / `smo.sftpPort` | Externally published ports (1830 / 1222), mapped to container 830 / 22. |
| `service.type` | `LoadBalancer` (default in both profiles) or `NodePort`. |
| `service.loadBalancerIP` | MetalLB address; keep it equal to `smo.advertisedHost`. |

Each adapter instance needs its own LB IP and its own `info.nodeId` — two
adapters sharing either will collide in MetalLB or in the SMO.

### Southbound — how the adapter reaches the gNB

| Key | Meaning |
| --- | --- |
| `telnet.host` | ClusterIP service DNS of the gNB (mono) or DU (split) management service. |
| `telnet.port` | Must match `--telnetsrv.listenport` on the gNB. |

A mismatch here is the most common failure: the adapter starts, registers with
VES, and then reports no gNB data.

### VES, identity and the rest

| Key | Meaning |
| --- | --- |
| `ves.url` | VES collector event listener endpoint. |
| `ves.username` / `ves.password` | VES basic-auth credentials. |
| `ves.pnfRegistration` | Send pnfRegistration on startup. |
| `ves.heartbeatInterval` | Heartbeat period, seconds. |
| `ves.pmDataInterval` / `ves.fileExpiry` | PM reporting interval and file retention. |
| `netconf.username` / `netconf.password` | Must match the netconf user baked into the image. |
| `info.nodeId` | Managed-element identity in the SMO; unique per adapter. |
| `info.gnbDuId` / `gnbCuId` / `cellLocalId` | Must match the IDs the gNB actually uses. |
| `info.managedElementType`, `model`, `unitType`, `locationName`, `managedBy` | NRM attributes reported to the SMO. |
| `alarms.*` | Connection-lost timeout and downlink-load warning threshold/timeout. |
| `pmStorage.enabled` / `size` / `storageClass` | Persist PM XML files across restarts. |
| `nodeSelector` / `tolerations` / `affinity` | Both profiles pin to the radio node and tolerate `dedicated=5g-radio:NoSchedule`. |
| `logLevel`, `softwareVersion`, `replicaCount`, `resources` | Standard runtime knobs. |

> The NETCONF and VES passwords are rendered in cleartext into the ConfigMap.
> For anything beyond a lab testbed, move them to a Secret.

The shipped profiles contain testbed-specific addresses (`192.168.206.106/.107`,
VES at `192.168.8.69:30417`) and placeholder image repositories
(`<REGISTRY_HOST>/<REGISTRY_NAMESPACE>`). Replace both before deploying.

---

## Verification

The chart's `NOTES.txt` prints a wiring summary and the checks below on install.

```bash
# pod and service
kubectl -n ravi-ns get pods -l app.kubernetes.io/instance=o1-mono -o wide
kubectl -n ravi-ns get svc  -l app.kubernetes.io/instance=o1-mono

# gNB telnet service must have endpoints
kubectl -n ravi-ns get endpoints oai-gnb-mgmt-external

# telnet reachable from inside the adapter pod
kubectl -n ravi-ns exec deploy/o1-mono-oai-o1-adapter -- \
  bash -lc "timeout 3 bash -c '</dev/tcp/oai-gnb-mgmt-external.ravi-ns.svc.cluster.local/9090' && echo TELNET_OK"

# NETCONF reachable from the SMO host
nc -vz 192.168.206.106 1830

# adapter logs: telnet connect + pnfRegistration
kubectl -n ravi-ns logs deploy/o1-mono-oai-o1-adapter -f
```

If SDNC lists the node but `connection-status` is not `connected`, the cause is
almost always `smo.advertisedHost` / `smo.netconfPort` not being routable from
the SMO.

---

## Build scripts

| Script | What it does |
| --- | --- |
| `scripts/native_build.sh` | Root/sudo. Installs build and NETCONF packages, creates the `netconf` user, clones the adapter source, builds `libssh`/`libyang`/`sysrepo`/`libnetconf2`/`netopeer2`, configures netopeer2 host keys, installs the 3GPP YANG models, compiles the adapter binary. |
| `scripts/docker_ci_build.sh` | Builds the adapter image from `docker/Dockerfile.adapter`, then patches `docker/Dockerfile.gNB.fhi72.ubuntu` in a sibling `openairinterface5g/` checkout to copy `libtelnetsrv.so`, `libtelnetsrv_ci.so` and `libtelnetsrv_o1.so` into the runtime image, adds a hard-fail check for the O1 library, builds the `oai-gnb` target and verifies the libraries via `ldconfig`. |

`docker_ci_build.sh` expects `openairinterface5g/` to already be cloned next to
it and edits that checkout's Dockerfile in place.

---

## Documentation

| Document | Contents |
| --- | --- |
| [Integration with SMO](<docs/integration with SMO.md>) | Testbed topology, data paths, adapter internals, configuration, deployment order, verification, troubleshooting, CU/DU-split notes. |
| [OAI gNB with O1 and O1-adapter build procedure](<docs/OAI gNB with o1 and O1-adapter build procedure.md>) | Native and Docker builds, FHI 7.2 O1-capable gNB image, optional OSC Near-RT RIC E2 agent, runtime config, troubleshooting. |
| [InfluxDB integration](<docs/InfluxDB integration.md>) | Placeholder — not yet written. |

---

## References

- [OAI O1-Adapter](https://gitlab.eurecom.fr/oai/o1-adapter)
- [OAI O1-Adapter — How to connect via O1](https://gitlab.eurecom.fr/oai/o1-adapter/-/blob/main/README.md?ref_type=heads#how-to-connect-via-o1)
- [OpenAirInterface 5G](https://gitlab.eurecom.fr/oai/openairinterface5g)

The upstream O1-Adapter source is distributed under the Collaborative Standards
Software License (CSSL) v1.0.
