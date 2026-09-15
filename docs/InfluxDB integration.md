# OAI O1 Adapter PM Data Flow to SMO InfluxDB

**Scope of this file.** Files 1 and 2 covered platform preparation, adapter/gNB
deployment, the NETCONF (CM) mount reaching `connection-status: connected` in
SDNC, and verification that the O1 adapter's `fileReady`/heartbeat events land on
the correct Kafka topic. **This file starts where that left off** and documents
the complete Performance Management (PM) path: how a PM measurement file created
by the O1 adapter travels, stage by stage, all the way into the SMO's InfluxDB
time-series database, ready for an rApp to query.

By the end of this file you will be able to: understand every hop the data
takes; verify each hop with concrete commands; know the exact PM parameter
values the OAI adapter must emit (and how OCUDU differs); rebuild the four
O-RAN-SC RANPM components from source when the upstream registry is unavailable;
and diagnose the specific failures encountered during bring-up.

---

## 1. Architecture overview

The PM pipeline is the O-RAN-SC **RANPM** (RAN Performance Management) chain,
running in the SMO. The RAN-side O1 adapter produces standard 3GPP PM XML files
and announces them over VES; the SMO-side RANPM components collect, convert,
distribute, and store the measurements.

```mermaid
flowchart TD
    subgraph RAN["RAN side (KVM / joule worker)"]
        GNB["OAI gNB<br/>(monolithic nr-softmodem)"]
        ADAPTER["O1 Adapter<br/>telnet 'o1 stats' poll<br/>builds 3GPP PM XML<br/>32.435 measCollecFile"]
        SFTP["SFTP server<br/>192.168.206.106:1222<br/>/ftp/*.xml"]
        GNB -->|telnet 9090| ADAPTER
        ADAPTER -->|writes XML| SFTP
    end

    subgraph SMO["SMO side (zhongkui, single node)"]
        VES["VES Collector<br/>:30417/eventListener/v7"]
        KAFKA["Kafka (Strimzi, KRaft)<br/>onap-strimzi-kafka-bootstrap.onap:9095<br/>SASL / OAuth"]
        DFC["DFC — DataFileCollector<br/>reads fileReady, SFTP-pulls file"]
        MINIO[("MinIO S3<br/>minio:9000<br/>bucket: ropfiles (raw XML)<br/>bucket: pm-files-json (converted)")]
        CONV["pm-file-converter<br/>(kafka-producer-pm-xml2json)<br/>XML -> JSON<br/>DATA_TYPE_FORMAT toggle"]
        PROD["pm-producer-json2kafka<br/>ICS job 'pmreports'<br/>filters + delivers"]
        PMLOG["pmlog (Influx Logger)<br/>consumes pmreports<br/>writes points"]
        INFLUX[("InfluxDB 2.x<br/>influxdb2:8086<br/>org: ravi-ric<br/>bucket: ran-pm-metrics")]
        ICS["Information Coordination Svc (ICS)<br/>informationservice.nonrtric:9082"]

        VES -->|domain routing| KAFKA
        KAFKA -->|SEC_3GPP_PERFORMANCEASSURANCE_OUTPUT| DFC
        DFC -->|store raw XML| MINIO
        DFC -->|collected-file topic| CONV
        CONV -->|store JSON| MINIO
        CONV -->|json-file-ready-kp / -kpadp| PROD
        PROD -->|pmreports topic| PMLOG
        PMLOG -->|line protocol write| INFLUX
        PMLOG -. registers job .-> ICS
        PROD -. reads job .-> ICS
    end

    subgraph RAPP["Consumer"]
        RAPP_APP["rApp / Grafana / Flux query"]
    end

    ADAPTER -->|VES fileReady POST| VES
    INFLUX --> RAPP_APP

    style GNB fill:#e1f5ff
    style ADAPTER fill:#e1f5ff
    style INFLUX fill:#d4edda
    style PMLOG fill:#d4edda
    style CONV fill:#fff3cd
```

### 1.1 The stages in words

1. **O1 Adapter** polls the gNB over telnet (`o1 stats`), assembles a 3GPP
   **TS 32.435 `measCollecFile`** PM XML every reporting period (30 s), writes it
   to its local SFTP directory, and sends a **VES `fileReady`** notification to
   the SMO VES collector.
2. **VES Collector** routes the event onto a Kafka topic **by its `domain`
   field**. A `stndDefined` / `3GPP-PerformanceAssurance` event lands on
   `unauthenticated.SEC_3GPP_PERFORMANCEASSURANCE_OUTPUT`.
3. **DFC (DataFileCollector)** consumes that topic, parses the `fileReady`
   (message class **TS28532**), **SFTP-pulls** the referenced XML from the
   adapter, stores the raw file in MinIO bucket **`ropfiles`**, and publishes a
   "file collected" record to the **`collected-file`** Kafka topic.
4. **pm-file-converter** (`kafka-producer-pm-xml2json`) consumes `collected-file`,
   reads the raw XML from MinIO, **converts XML → JSON**, stores the JSON in
   MinIO bucket **`pm-files-json`**, and publishes readiness to
   **`json-file-ready-kp`** / **`json-file-ready-kpadp`**.
5. **pm-producer-json2kafka** consumes the json-file-ready topic, reads the JSON,
   applies the **ICS Information Job** filter (job `pmreports`), and delivers the
   filtered PM report to the **`pmreports`** Kafka topic.
6. **pmlog (Influx Logger)** consumes `pmreports` and **writes** each measurement
   as a point into **InfluxDB** (`ran-pm-metrics`, org `ravi-ric`).
7. **rApp / Grafana / Flux** reads `ran-pm-metrics`.

### 1.2 Why the transport looks the way it does

- **Topic is chosen by VES `domain`, not by configuration.** `domain:
  stndDefined` + `stndDefinedNamespace: 3GPP-PerformanceAssurance` → the
  perf-assurance topic. `domain: notification` → `VES_NOTIFICATION_OUTPUT`. The
  emitter picks the topic implicitly through the format it sends.
- **DFC's parser is fixed per instance** by `FILE_READY_MESSAGE_CLASS`
  (`TS28532` vs default). One DFC instance parses exactly one `fileReady` format.
- **The converter's struct is fixed per instance** by `DATA_TYPE_FORMAT`
  (`measCollecFile` vs `measDataFile`). One converter instance parses exactly one
  XML root format. This single global toggle is the crux of the OAI-vs-OCUDU
  interplay (see §4 and §6.6).
- **InfluxDB separates sources automatically** because the measurement name is
  the measured resource's FDN (`measObjLdn`). Two gNBs with different FDNs never
  collide, even in the same bucket.

---

## 2. Message Sequence Chart (MSC) — end-to-end data flow

```mermaid
sequenceDiagram
    autonumber
    participant GNB as OAI gNB
    participant ADP as O1 Adapter
    participant SFTP as Adapter SFTP<br/>(.106:1222)
    participant VES as VES Collector
    participant KAF as Kafka<br/>(Strimzi)
    participant DFC as DFC
    participant S3 as MinIO S3
    participant CNV as pm-file-converter
    participant PRD as pm-producer
    participant PML as pmlog
    participant IDB as InfluxDB
    participant ICS as ICS

    Note over PML,ICS: One-time: pmlog registers info-job 'pmlog' (delivery topic = pmreports)
    PML->>ICS: PUT /data-consumer/v1/info-jobs/pmlog
    ICS-->>PML: 200 registration succeeded
    PML->>KAF: subscribe topic 'pmreports'

    loop every 30s reporting period
        ADP->>GNB: telnet "o1 stats"
        GNB-->>ADP: counter values
        ADP->>ADP: build 32.435 measCollecFile XML
        ADP->>SFTP: write A<ts>_1_oai-gnb-mono.xml
        ADP->>VES: POST fileReady (domain=stndDefined,<br/>3GPP-PerformanceAssurance, TS28532)
        VES->>KAF: publish to SEC_3GPP_PERFORMANCEASSURANCE_OUTPUT
        KAF-->>DFC: fileReady event
        DFC->>DFC: parse TS28532FileReadyMessage
        DFC->>SFTP: SFTP GET the XML file
        SFTP-->>DFC: file bytes (1.5 KiB)
        DFC->>S3: PUT ropfiles/oai-gnb-mono/<file>.xml
        DFC->>KAF: publish 'collected-file'
        KAF-->>CNV: collected-file event
        CNV->>S3: GET ropfiles/.../<file>.xml
        CNV->>CNV: xml.Unmarshal -> MeasCollecFile struct<br/>(DATA_TYPE_FORMAT="")
        CNV->>S3: PUT pm-files-json/.../<file>.json.gz (~485 B)
        CNV->>KAF: publish json-file-ready-kp / -kpadp
        KAF-->>PRD: json-file-ready event
        PRD->>S3: GET pm-files-json/.../<file>.json.gz
        PRD->>PRD: apply ICS job filter (pmreports)
        PRD->>KAF: publish 'pmreports'
        KAF-->>PML: pmreports event
        PML->>PML: map FDN->measurement, measType->field
        PML->>IDB: write line protocol (bucket ran-pm-metrics)
        IDB-->>PML: 204 written
    end

    Note over IDB: rApp / Grafana / Flux query ran-pm-metrics
```

---

## 3. Prerequisites carried over from Files 1 & 2

Before any PM data can flow, the following must already be true (verified in
File 2):

| Item | Expected state | Quick re-check |
|---|---|---|
| gNB running | telnet `o1 stats` answered | `kubectl -n ravi-ns get pods` |
| O1 adapter running | VES `202`, heartbeat sent | adapter logs show `Successfully send event` |
| NETCONF/CM mount | `connection-status: connected` in SDNC | SDNC RESTCONF GET of the node |
| VES → Kafka | fileReady visible on perf-assurance topic | §5.1 console-consumer |
| UE attached (for non-zero counters) | UE in `CONNECTED`, traffic running | gNB logs / iperf3 |

> **Note on counter values.** With no UE attached, the adapter still emits a PM
> file every 30 s, but the active-UE / throughput / PRB counters are zero.
> Attach a UE and run continuous traffic (e.g. `iperf3`) to populate non-zero
> values across successive reporting windows.

---

## 4. PM parameter reference — exact values for OAI (and OCUDU differences)

This is the single most important table for reproducing the integration. Every
value below was taken from a working OAI PM file and the working SMO config.

### 4.1 VES `fileReady` notification (adapter → VES → Kafka)

| Parameter | OAI value (required) | OCUDU value | Notes |
|---|---|---|---|
| `commonEventHeader.domain` | `stndDefined` | `stndDefined` (after convergence) | **Determines the Kafka topic.** Legacy OCUDU used `notification`. |
| `stndDefinedNamespace` | `3GPP-PerformanceAssurance` | same | Routes to `SEC_3GPP_PERFORMANCEASSURANCE_OUTPUT`. |
| `eventName` | `stndDefined_OpenAirInterface-nr-softmodem_OAI_FileReady` | `stndDefined_OCUDU_FileReady` | Cosmetic; source identification. |
| `sourceName` | `oai-gnb-mono` | `ocududu` | Also appears as file/DN prefix. |
| `stndDefinedFields.data.notificationType` | `notifyFileReady` | `notifyFileReady` | TS28532 notification type. |
| `data.fileInfoList[].fileLocation` | `sftp://netconf:netconf!@192.168.206.106:1222/ftp/<file>.xml` | `http://<ocudu-oam>:5000/files/<file>` | **DFC reads the transport from the URL scheme** — SFTP for OAI, HTTP for OCUDU. |
| `data.fileInfoList[].fileFormat` | `xml` | `xml` | |
| `data.fileInfoList[].fileDataType` | `Performance` | `Performance` | |
| `data.eventTime` | ISO-8601 e.g. `2026-08-25T07:10:00.226Z` | ISO-8601 | Must be ISO-8601 for TS28532 (OCUDU legacy used RFC-1123; that was corrected). |
| `schemaReference` | `.../TS28532_FileDataReportingMnS.yaml#components/schemas/NotifyFileReady` | same | |

**Kafka topic that results:** `unauthenticated.SEC_3GPP_PERFORMANCEASSURANCE_OUTPUT`

### 4.2 PM measurement XML body (the file DFC pulls)

The OAI adapter emits **TS 32.435 `measCollecFile`**. Full working example:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<?xml-stylesheet type="text/xsl" href="MeasDataCollection.xsl"?>
<measCollecFile xmlns="http://www.3gpp.org/ftp/specs/archive/32_series/32.435#measCollec"
  xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
  xsi:schemaLocation="http://www.3gpp.org/ftp/specs/archive/32_series/32.435#measCollec ...">
  <fileHeader fileFormatVersion="32.435 V7.0" vendorName="OpenAirInterface" dnPrefix="DC=openairinterface.org">
    <fileSender localDn="ManagedElement=oai-gnb-mono" elementType="GNBDU"/>
    <measCollec beginTime="2026-08-25T09:21:00+00:00"/>
  </fileHeader>
  <measData>
    <managedElement localDn="ManagedElement=oai-gnb-mono" userLabel=""/>
    <measInfo>
      <job jobId="1"/>
      <granPeriod duration="PT30S" endTime="2026-08-25T09:21:30+00:00"/>
      <repPeriod duration="P1D"/>
      <measType p="1">DRB.MeanActiveUeDl</measType>
      <measType p="2">DRB.MaxActiveUeDl</measType>
      <measType p="3">DRB.MeanActiveUeUl</measType>
      <measType p="4">DRB.MaxActiveUeUl</measType>
      <measType p="5">RRU.PrbTotDl</measType>
      <measType p="6">DRB.UEThpDl</measType>
      <measType p="7">DRB.UEThpUl</measType>
      <measValue measObjLdn="DuFunction=3602,CellId=1">
        <r p="1">1</r>
        <r p="2">1</r>
        <r p="3">1</r>
        <r p="4">1</r>
        <r p="5">0</r>
        <r p="6">0</r>
        <r p="7">0</r>
      </measValue>
    </measInfo>
  </measData>
  <fileFooter>
    <measCollec endTime="2026-08-25T09:21:30+00:00"/>
  </fileFooter>
</measCollecFile>
```

**Parameter table for the XML body:**

| XML element / attribute | OAI value | OCUDU value | Consumed by | Notes |
|---|---|---|---|---|
| root element | `measCollecFile` | `measDataFile` | converter struct selector | **32.435 vs 28.532.** This is the value the `DATA_TYPE_FORMAT` toggle must match. |
| root `xmlns` | `...32_series/32.435#measCollec` | `...28_series/28.532#measData` | converter | |
| `fileHeader/fileSender@localDn` | `ManagedElement=oai-gnb-mono` | `ManagedElement=ran1,...` | converter → `MeasuredEntityDn` | For `measCollecFile` the converter reads `fileSender.LocalDn`; for `measDataFile` it reads `fileSender.SenderName`. |
| `fileSender@elementType` | `GNBDU` | (n/a) | informational | |
| `measInfo` | present (no `measInfoId`) | `measInfo measInfoId="PM"` | converter → `MeasInfoID` | Optional; empty is tolerated. |
| `granPeriod@duration` | `PT30S` | `PT60S` (example) | informational | Reporting granularity. |
| `granPeriod@endTime` | ISO-8601 | ISO-8601 | timestamp basis | |
| `measType@p` (1..7) | ordered list of 7 counters | OCUDU's own counter set | converter → field names | The `p` index links `measType` to each `<r p="N">`. |
| `measValue@measObjLdn` | `DuFunction=3602,CellId=1` | `GNBDUFunction=du1,NRCellDU=nrcelldu1` | pmlog → **InfluxDB measurement name** | **This becomes the InfluxDB measurement**, so OAI and OCUDU never collide. |
| `<r p="N">value` | counter value | counter value | pmlog → field value | |
| `suspect` | (absent → `false`) | (absent → `false`) | converter → `SuspectFlag` | |

**The 7 OAI DU counters:**

| `p` | measType | Meaning |
|---|---|---|
| 1 | `DRB.MeanActiveUeDl` | Mean active UEs downlink |
| 2 | `DRB.MaxActiveUeDl` | Max active UEs downlink |
| 3 | `DRB.MeanActiveUeUl` | Mean active UEs uplink |
| 4 | `DRB.MaxActiveUeUl` | Max active UEs uplink |
| 5 | `RRU.PrbTotDl` | Total PRB downlink |
| 6 | `DRB.UEThpDl` | UE throughput downlink |
| 7 | `DRB.UEThpUl` | UE throughput uplink |

### 4.3 SMO component configuration values

| Component | Key | Value | Where |
|---|---|---|---|
| DFC | `FILE_READY_EVENT_TOPIC` | `unauthenticated.SEC_3GPP_PERFORMANCEASSURANCE_OUTPUT` | StatefulSet env |
| DFC | `FILE_READY_MESSAGE_CLASS` | `TS28532` | StatefulSet env |
| DFC | output topic | `collected-file` | `dfc-cm` |
| DFC | S3 bucket (raw) | `ropfiles` | `dfc-cm` |
| DFC | Kafka bootstrap | `onap-strimzi-kafka-bootstrap.onap:9095` | `dfc-cm` |
| converter | `DATA_TYPE_FORMAT` | **`""` (empty)** for OAI `measCollecFile` | StatefulSet env (index 3) |
| converter | input topic | `collected-file` | `kafka-producer-pm-xml2json-cm-config` |
| converter | output topics | `json-file-ready-kp`, `json-file-ready-kpadp` | config |
| converter | S3 bucket (JSON) | `pm-files-json` | derived |
| pm-producer | ICS job served | `pmreports` | ICS info-job |
| pm-producer | delivery topic | `pmreports` | ICS job `deliveryInfo` |
| pmlog | `info_type_id` | `PmData` | `pmlog-job-cm` |
| pmlog | filter | all empty `[]` (= all sources/measTypes) | `pmlog-job-cm` |
| pmlog | deliveryInfo topic | `pmreports` | `pmlog-job-cm` |
| pmlog | Influx URL | `http://influxdb2:8086` | `pmlog-app-cm` |
| pmlog | Influx bucket | `ran-pm-metrics` | `pmlog-app-cm` (live) |
| pmlog | Influx org | `ravi-ric` | `pmlog-app-cm` (live) |
| MinIO | endpoint / creds | `minio:9000` / `admin` / `adminadmin` | env |
| InfluxDB | UI | `http://192.168.8.69:30138` (org-id `dc668a9e4792993e`) | NodePort |

> **`DATA_TYPE_FORMAT` is the single most important toggle in this file.**
> Empty → converter parses `measCollecFile` (OAI). Non-empty (e.g. `xml`) →
> converter parses `measDataFile` (OCUDU). It is global to the converter, so
> only one XML format can be served at a time (see §6.6 for the both-gNB story).

---

## 5. Step-by-step verification (each hop)

Run these in order. Each confirms one hop of the MSC. All SMO commands run on
`zhongkui`.

### 5.1 Hop 1–2: fileReady reaches the perf-assurance Kafka topic

```bash
# Confirm the OAI fileReady is on the topic (domain routing worked).
# Find the broker pod:
kubectl -n onap get pods | grep -iE 'strimzi.*broker'
# -> onap-strimzi-onap-strimzi-broker-0

# Inspect the raw event on the topic (structure check).
# Look for: domain=stndDefined, 3GPP-PerformanceAssurance, sourceName=oai-gnb-mono,
# fileLocation=sftp://...:1222/ftp/...xml
```

Expected `fileReady` (abridged):

```json
{"event":{"commonEventHeader":{
  "domain":"stndDefined",
  "sourceName":"oai-gnb-mono",
  "stndDefinedNamespace":"3GPP-PerformanceAssurance"},
 "stndDefinedFields":{"data":{
  "notificationType":"notifyFileReady",
  "fileInfoList":[{"fileLocation":
    "sftp://netconf:netconf!@192.168.206.106:1222/ftp/A....xml",
    "fileFormat":"xml","fileDataType":"Performance"}]}}}}
```

### 5.2 Hop 3: DFC consumes, SFTP-pulls, stores raw XML

```bash
kubectl -n smo logs dfc-0 -c dfc -f | grep -iE 'Listening|Received|TS28532|sftp|Download|Stored'
```

Success markers:

```
Listening to kafka topic: unauthenticated.SEC_3GPP_PERFORMANCEASSURANCE_OUTPUT
Received: org.oran.datafile.model.TS28532FileReadyMessage
StrictHostKeyChecking will be disabled.
File A2026....xml Download successful from xNF
Stored file in S3: oai-gnb-mono/A2026....xml
```

Confirm the raw XML in MinIO (raw file is ~1.5 KiB):

```bash
kubectl -n smo exec minio-0 -c minio -- sh -c \
 'mc alias set local http://localhost:9000 admin adminadmin 2>/dev/null; \
  mc ls local/ropfiles/oai-gnb-mono/ | tail -3'
```

### 5.3 Hop 4: converter produces JSON (NOT 23 bytes)

```bash
kubectl -n smo exec kafka-producer-pm-xml2json-0 -- printenv DATA_TYPE_FORMAT   # must be blank
kubectl -n smo logs kafka-producer-pm-xml2json-0 --tail=20 | grep -viE 'Nothing to consume'
kubectl -n smo exec minio-0 -c minio -- sh -c \
 'mc alias set local http://localhost:9000 admin adminadmin 2>/dev/null; \
  mc ls local/pm-files-json/oai-gnb-mono/ | tail -3'
```

**Decisive check:** converted `.json.gz` size must be **hundreds of bytes**
(≈485 B), **not 23 bytes**. 23 bytes = gzip of an empty string = the converter
parsed into the wrong struct (see §6.6).

### 5.4 Hop 5: pm-producer builds and delivers to `pmreports`

```bash
kubectl -n smo logs pm-producer-json2kafka-0 -c pm-producer-json2kafka --tail=30 \
 | grep -viE 'OAuth|callback|Sasl'
```

Success markers (NOT `value=[]` / "report is null"):

```
JobDataDistributor - Received data, job pmreports
JobDataDistributor - Filtered data, job pmreports
JobDataDistributor - Sending data '{"event":{' to Kafka topic: ...KafkaDeliveryInfo
JobDataDistributor - Sent data to Kafka topic: ...KafkaDeliveryInfo
```

### 5.5 Hop 6: pmlog writes to InfluxDB

```bash
kubectl -n smo logs pmlog-0 -c pmlog -f | grep -iE 'InfluxStore|Processed file|Stored data|Token validation'
```

Success markers (no `Token validation failed`):

```
InfluxStore - Influx version v2.7.12
ConsumerRegstrationTask - Registration of subscription/info job succeeded
InfluxStore - Processed file from: oai-gnb-mono
InfluxStore - Stored data
```

### 5.6 Hop 7: query InfluxDB

InfluxDB UI: `http://192.168.8.69:30138` (org `ravi-ric`, bucket
`ran-pm-metrics`). Flux:

```flux
from(bucket: "ran-pm-metrics")
  |> range(start: -30m)
  |> filter(fn: (r) => r._measurement =~ /DuFunction=3602/)
  |> last()
```

List all measurements to see the FDN landed:

```flux
import "influxdata/influxdb/schema"
schema.measurements(bucket: "ran-pm-metrics")
```

You should see measurement `DuFunction=3602,CellId=1` with the 7 counters as
fields and non-zero values while a UE is passing traffic.

### 5.7 One-shot health snapshot

```bash
kubectl -n smo get pods | grep -iE 'dfc|xml2json|pm-producer|pmlog|minio|influx'
# all expected 1/1 or 2/2 Running
```

---

## 6. Issues encountered during bring-up (and the fixes)

This section documents every real problem hit while bringing the PM pipeline up,
so a future run can skip the dead ends.

### 6.1 O-RAN-SC nexus3 registry returns `402 Invalid license`

**Symptom.** Any pull from `nexus3.o-ran-sc.org:10002/o-ran-sc/...` fails:

```
failed to resolve image: unexpected status from HEAD request to
https://nexus3.o-ran-sc.org:10002/v2/o-ran-sc/<image>/manifests/<tag>: 402 Invalid license
```

This affects **every** RANPM component image (DFC, pm-file-converter,
pm-producer, pmlog) and the `auth-token-fetch` sidecar. It hits `docker`,
`crictl`, authenticated and anonymous clients alike — the registry itself is
refusing to serve.

**Fix.** Rebuild each image from source (§7) and side-load it onto the node,
then repoint the workload with `imagePullPolicy: IfNotPresent`.

> **Operational caution learned the hard way:** do **not** `kubectl delete pod`
> on a nexus3-sourced component while the registry is down **unless** its image
> is already cached on the node. Deleting the pod forces a fresh pull that then
> 402s. Verify the cache first:
> `sudo crictl images | grep -i <component>`.

### 6.2 Registry delivery: `401 UNAUTHORIZED` from the private registry

**Symptom.** After pushing a rebuilt image to `<REGISTRY_HOST>/<REGISTRY_NAMESPACE>/...`,
the SMO node cannot pull it:

```
...manifests/1.2.0: 401 UNAUTHORIZED
```

The private registry is reachable but requires auth the node doesn't have.

**Fix (chosen).** Bypass the registry entirely with `ctr import` — save the
image to a tar on the KVM, `scp` it to `zhongkui`, and import into containerd's
`k8s.io` namespace. Then `IfNotPresent` uses the local image with no pull. This
is ideal for a **single-node** SMO. (Alternative: create a
`docker-registry` pull secret and attach it to the pod spec.)

### 6.3 The jar-directory packaging bug (pm-producer and pmlog crash-loop)

**Symptom.** After rebuild, `pm-producer` and `pmlog` reach `2/2 Running`
briefly, then `Error` → `CrashLoopBackOff`, exit code 1.

**Root cause.** The upstream Dockerfiles copy the jar via a build-arg:

```dockerfile
ADD target/${JAR} /opt/app/<svc>/<svc>.jar
```

The `${JAR}` variable is normally substituted by the fabric8
`docker-maven-plugin` **during the Maven build**. We bypassed that plugin
(no `docker.sock` in the Maven container), so `${JAR}` was empty and the line
became `ADD target/ ...` — copying the **entire `target/` directory** to a path
named `<svc>.jar`. The result: `<svc>.jar` is a **directory**, not a file, so
`java -jar` fails instantly.

Confirm the bug inside a built image:

```bash
docker run --rm --entrypoint sh <image> -c "ls -la /opt/app/<svc>-service/"
# BAD:  drwxr-xr-x ... <svc>.jar   (a directory)
# GOOD: -rw-r--r-- ... <svc>.jar   (a ~66-73 MB file)
```

**Fix.** Hard-code the real jar name in the Dockerfile (see §7.3), then rebuild
`--no-cache`. DFC did **not** hit this because its Dockerfile already hard-coded
`target/datafile-collector.jar`.

### 6.4 Stale Keycloak OAuth tokens (`Token validation failed: Unknown signing key`)

**Symptom.** `pm-producer` and `pmlog` (long-running since before a Keycloak key
rotation) fail Kafka SASL/OAuth:

```
SaslAuthenticationException: Token validation failed:
Unknown signing key (kid:...)
JobDataDistributor stopped jobId: pmreports
InfluxStore stopped
```

**Root cause.** Keycloak rotated its signing keys; these pods held cached tokens
signed by the now-unknown key and never re-fetched. DFC, restarted after the
rotation, authenticated fine — proving fresh tokens work with the current keys.

**Fix.** Restart the affected pods so their `auth-token` sidecar fetches a fresh
token. (In our run the restart coincided with the image rebuild, so both were
resolved together.)

### 6.5 Kafka consumer-group authorization (`GroupAuthorizationException`)

**Symptom.** After pointing DFC (`service-account-dfc`) at the perf-assurance
topic:

```
GroupAuthorizationException: Not authorized to access group:
osc-dmaap-adapter-unauthenticated.SEC_3GPP_PERFORMANCEASSURANCE_OUTPUT
```

**Root cause.** `service-account-dfc` had a **topic** read ACL for
`unauthenticated.SEC_3GPP_PERFORMANCEASSURANCE_OUTPUT` but **not** the matching
**consumer-group** ACL. The group name is derived per topic
(`osc-dmaap-adapter-<topic>`), so a new topic created a new group name that was
not yet authorized.

**Fix (additive, safe — grants only, removes nothing).**

```bash
kubectl -n onap patch kafkauser service-account-dfc --type json -p '[
  {"op":"add","path":"/spec/authorization/acls/-","value":{
    "operations":["Read"],
    "resource":{"type":"group",
      "name":"osc-dmaap-adapter-unauthenticated.SEC_3GPP_PERFORMANCEASSURANCE_OUTPUT",
      "patternType":"literal"}}}
]'
```

Strimzi reconciles the ACL into Kafka within ~10-30 s; restart `dfc-0` to retry.
Verify:

```bash
kubectl -n onap get kafkauser service-account-dfc -o yaml \
 | sed -n '/authorization/,/status/p' | grep -A3 PERFORMANCEASSURANCE
# expect BOTH a 'topic' and a 'group' entry for PERFORMANCEASSURANCE
```

### 6.6 The empty-JSON conversion — `DATA_TYPE_FORMAT` mismatch (the final blocker)

**Symptom.** Everything mechanical works — DFC collects, converter runs,
pm-producer receives, pmlog subscribes — but InfluxDB stays empty. Tracing:

- converter uploads JSON of **`size:23`** (gzip of empty string);
- pm-producer logs `Could not parse PM data ... value=[] ... "report" is null`;
- pmlog receives nothing.

**Root cause.** The converter chooses its XML struct from an env var:

```go
var datatypeformat = os.Getenv("DATA_TYPE_FORMAT")
if datatypeformat == "" {
    f = &dataTypes.MeasCollecFile{}   // 32.435 root <measCollecFile>
} else {
    f = &dataTypes.MeasDataFile{}     // 28.532 root <measDataFile>
}
err := xml.Unmarshal(*fBytevalue, &f)
```

The deployed value was `DATA_TYPE_FORMAT=xml`, so the converter tried to
unmarshal OAI's `measCollecFile` document into the `MeasDataFile` struct. The
root element didn't match → the struct stayed empty → 23-byte empty JSON out.
The `MeasCollecFile` struct matches OAI's XML **exactly** (verified field by
field: `fileHeader/fileSender/localDn`, `measData/measInfo/measType`,
`measValue/measObjLdn`, `r/p`), so the only thing wrong was the toggle.

**Fix.** Set `DATA_TYPE_FORMAT` empty on the converter and restart:

```bash
# DATA_TYPE_FORMAT was env index 3 in our StatefulSet — confirm first:
kubectl -n smo get statefulset kafka-producer-pm-xml2json \
 -o jsonpath='{range .spec.template.spec.containers[0].env[*]}{.name}{"\n"}{end}' | nl -v0

kubectl -n smo patch statefulset kafka-producer-pm-xml2json --type json -p '[
  {"op":"replace","path":"/spec/template/spec/containers/0/env/3/value","value":""}
]'
kubectl -n smo delete pod kafka-producer-pm-xml2json-0
kubectl -n smo exec kafka-producer-pm-xml2json-0 -- printenv DATA_TYPE_FORMAT   # blank
```

After this the converted JSON jumps from 23 B to ~485 B and data flows all the
way to InfluxDB.

> **OAI vs OCUDU tension.** `DATA_TYPE_FORMAT` is global to the converter:
> empty → `measCollecFile` (OAI), non-empty → `measDataFile` (OCUDU). Because
> the two gNBs are run **one after the other** (never simultaneously), there are
> two ways to support both:
>
> - **Option A (per-session toggle):** flip `DATA_TYPE_FORMAT` (empty for OAI,
>   `xml` for OCUDU) and restart the converter each time you switch gNB.
> - **Option B (converge, recommended):** change OCUDU's PM XML writer
>   (`pm_reporter_filetype.py`) to emit `measCollecFile` (32.435) like OAI, so
>   `DATA_TYPE_FORMAT=""` serves **both** with no per-session change. Both
>   formats are valid 3GPP; 32.435 is chosen because OAI's XML is generated
>   inside the adapter (hard to change) while OCUDU's is editable Python. This
>   mirrors the earlier `fileReady` convergence (OCUDU → TS28532).

### 6.7 Restarting a nexus3 component re-triggers the 402

**Symptom.** Editing an env var on the converter and restarting the pod caused
`ErrImagePull` (402) because the pod's image was still the nexus3 reference and
was not cached.

**Fix.** Rebuild the converter from source (§7), `ctr import`, and **repoint the
StatefulSet to the local image with `IfNotPresent`** — the same pattern as the
other three components. After repointing, env changes + restarts no longer touch
nexus3.

### 6.8 DFC benign log lines (safe to ignore)

| Line | Why it's harmless |
|---|---|
| `Could not setup HttpsClient certs ... Unable to prepare HttpsConnectionManager` | FTPES cert init only; OAI uses SFTP, not FTPES. |
| `Could not create S3 bucket: ... already own it (409)` | Bucket already exists = success. |
| init container waits on `unauthenticated.ves-notification-output-kt` | That topic exists; the wait passes. |

---

## 7. Rebuilding the RANPM images from source (generalised)

All four images were cloned from
`github.com/o-ran-sc/nonrtric-plt-ranpm` onto the build host (KVM) at
`~/nonrtric-plt-ranpm`. The subdirectories used:

| Component | Source dir | Rebuilt image tag | Language |
|---|---|---|---|
| DataFileCollector | `datafilecollector/` | `<REGISTRY_HOST>/<REGISTRY_NAMESPACE>/nonrtric-plt-ranpm-datafilecollector:1.2.0` | Java |
| pm-file-converter | `pm-file-converter/` | `<REGISTRY_HOST>/<REGISTRY_NAMESPACE>/nonrtric-plt-ranpm-pm-file-converter:1.2.0` | Go |
| pm-producer | `pmproducer/` | `<REGISTRY_HOST>/<REGISTRY_NAMESPACE>/nonrtric-plt-pmproducer:1.1.0` | Java |
| pmlog (Influx Logger) | `influxlogger/` | `<REGISTRY_HOST>/<REGISTRY_NAMESPACE>/nonrtric-plt-pmlog:1.1.0` | Java |

> **Naming quirk:** the pmlog source directory is `influxlogger/`, but the
> image the StatefulSet expects is `nonrtric-plt-pmlog`. Tag it as
> `nonrtric-plt-pmlog`, not `influxlogger`.

The `auth-token-fetch:1.1.1` sidecar image was **already cached** on the node
(DFC uses it) and did not need rebuilding.

### 7.1 The general build recipe (applies to all four)

Every Dockerfile references nexus3 base images. The universal preparation is to
repoint those bases to Docker Hub, then build.

```bash
cd ~/nonrtric-plt-ranpm/<component-dir>

# 0) back up the original Dockerfile
cp Dockerfile Dockerfile.orig

# 1) repoint nexus3 base images to Docker Hub
sed -i \
  -e 's#nexus3.o-ran-sc.org:10001/##g' \
  -e 's#nexus3.o-ran-sc.org:10002/o-ran-sc/##g' \
  Dockerfile
grep -n '^FROM' Dockerfile   # confirm bases are now docker.io images
```

### 7.2 Java components (DFC, pmproducer, pmlog) — build the jar first

The Java components normally build the jar **and** the image together via the
fabric8 Maven plugin. Since we lack `docker.sock` inside the Maven container,
build only the jar with Maven, then build the image with `docker build`:

```bash
# build the jar (the fabric8 "docker build" goal fails harmlessly — ignore it;
# the jar under target/ is what matters)
docker run --rm -v "$PWD":/src -w /src maven:3.9-eclipse-temurin-17 \
  mvn -B -DskipTests clean package

ls -l target/*.jar          # note the EXACT jar name, e.g. pmproducer-1.2.0-SNAPSHOT.jar
grep -in 'jar' Dockerfile | grep -iE 'add|copy'   # see how the Dockerfile copies it
```

### 7.3 Fix the jar-directory bug (pmproducer, pmlog) — §6.3

If the Dockerfile uses `ADD target/${JAR} ...` or `ADD target/ ...`, hard-code
the real jar name so a **file** (not a directory) is copied:

```bash
# pmproducer example (dir=pmproducer, path=/opt/app/pm-producer-service/pmproducer.jar):
sed -i 's#^ADD target/.* /opt/app/pm-producer-service/pmproducer.jar#ADD target/pmproducer-1.2.0-SNAPSHOT.jar /opt/app/pm-producer-service/pmproducer.jar#' Dockerfile

# pmlog example (dir=influxlogger, path=/opt/app/pmlog-service/pmlog.jar):
sed -i 's#^ADD target/.* /opt/app/pmlog-service/pmlog.jar#ADD target/pmlog-1.2.0-SNAPSHOT.jar /opt/app/pmlog-service/pmlog.jar#' Dockerfile

grep -n 'jar' Dockerfile | grep -iE 'add|copy'   # verify the specific jar name
```

Build the image (use `--no-cache` after a Dockerfile edit so the old broken
layer isn't reused):

```bash
docker build --no-cache -t <image-tag> .

# CRITICAL verification — the jar must be a FILE, not a directory:
docker run --rm --entrypoint sh <image-tag> -c "ls -la /opt/app/<svc>-service/<svc>.jar"
# GOOD: -rw-r--r-- ... <svc>.jar   (~66-73 MB)
# BAD:  drwxr-xr-x ... <svc>.jar
```

### 7.4 Go component (pm-file-converter)

The converter is Go. After repointing the base images (§7.1), a single
`docker build` suffices (multi-stage Dockerfile compiles the binary):

```bash
cd ~/nonrtric-plt-ranpm/pm-file-converter
docker build -t <REGISTRY_HOST>/<REGISTRY_NAMESPACE>/nonrtric-plt-ranpm-pm-file-converter:1.2.0 .
```

### 7.5 Side-load onto the SMO node and repoint (all four, identical pattern)

Because the private registry pull 401s on the node (§6.2), deliver via
`ctr import`:

```bash
# on the KVM: save + copy
docker save <image-tag> -o /tmp/<name>.tar
scp /tmp/<name>.tar ubuntu@192.168.8.69:/tmp/

# on zhongkui: import into containerd's k8s namespace
sudo ctr -n k8s.io images import /tmp/<name>.tar
sudo crictl images | grep -i <name>          # confirm present with correct repo:tag
```

Repoint the workload to the local image with `IfNotPresent`. Always confirm
container **indices** first (the app and the `auth-token` sidecar order differs
per workload):

```bash
kubectl -n smo get statefulset <sts> \
 -o jsonpath='{range .spec.template.spec.containers[*]}{.name}{"="}{.image}{"\n"}{end}'

# then patch the app container's image + IfNotPresent (indices from the line above)
kubectl -n smo patch statefulset <sts> --type json -p '[
  {"op":"replace","path":"/spec/template/spec/containers/<APP_IDX>/image","value":"<image-tag>"},
  {"op":"replace","path":"/spec/template/spec/containers/<APP_IDX>/imagePullPolicy","value":"IfNotPresent"},
  {"op":"replace","path":"/spec/template/spec/containers/<TOKEN_IDX>/imagePullPolicy","value":"IfNotPresent"}
]'
kubectl -n smo delete pod <sts>-0
kubectl -n smo get pods | grep <sts>
```

**Container index reference (as deployed here):**

| StatefulSet | index 0 | index 1 |
|---|---|---|
| `dfc` | `dfc` (app) | `auth-token` |
| `pmlog` | `auth-token` | `pmlog` (app) |
| `pm-producer-json2kafka` | `pm-producer-json2kafka` (app) | `auth-token` |
| `kafka-producer-pm-xml2json` | app | (init only: `wait-for-keycloak-and-kafka`) |

### 7.6 Worked example (DFC, end to end)

```bash
cd ~/nonrtric-plt-ranpm/datafilecollector
# Dockerfile already hard-codes target/datafile-collector.jar (no §6.3 fix needed)
sed -i -e 's#nexus3.o-ran-sc.org:10001/##g' -e 's#nexus3.o-ran-sc.org:10002/o-ran-sc/##g' Dockerfile
docker run --rm -v "$PWD":/src -w /src maven:3.9-eclipse-temurin-17 mvn -B -DskipTests clean package
docker build -t <REGISTRY_HOST>/<REGISTRY_NAMESPACE>/nonrtric-plt-ranpm-datafilecollector:1.2.0 .
docker save <REGISTRY_HOST>/<REGISTRY_NAMESPACE>/nonrtric-plt-ranpm-datafilecollector:1.2.0 -o /tmp/dfc.tar
scp /tmp/dfc.tar ubuntu@192.168.8.69:/tmp/
# on zhongkui:
sudo ctr -n k8s.io images import /tmp/dfc.tar
sudo crictl images | grep datafilecollector
kubectl -n smo patch statefulset dfc --type json -p '[
  {"op":"replace","path":"/spec/template/spec/containers/0/image","value":"<REGISTRY_HOST>/<REGISTRY_NAMESPACE>/nonrtric-plt-ranpm-datafilecollector:1.2.0"},
  {"op":"replace","path":"/spec/template/spec/containers/0/imagePullPolicy","value":"IfNotPresent"},
  {"op":"replace","path":"/spec/template/spec/containers/1/imagePullPolicy","value":"IfNotPresent"}
]'
kubectl -n smo delete pod dfc-0
```

---

## 8. Two-DFC vs one-DFC (design note)

During bring-up a second collector, `dfc-oai`, was created (clone of `dfc` with
the OAI topic/class). Because OAI and OCUDU run **one at a time**, the simpler
converged design is:

- **One DFC** (`dfc`) pointed at `SEC_3GPP_PERFORMANCEASSURANCE_OUTPUT` +
  `TS28532`, serving whichever gNB is running.
- **Everything downstream is shared** — converter, producer, pmlog, InfluxDB —
  and needs no per-source duplication.
- **No new ICS job** is required: `pmlog-job-cm` uses an empty filter (`[]` =
  all sources), so it already covers OAI.
- **InfluxDB separation is automatic by FDN** (OAI `DuFunction=3602,CellId=1`
  vs OCUDU `GNBDUFunction=du1,NRCellDU=nrcelldu1`).

If both gNBs must ever run **simultaneously**, use two DFCs (one per format) and
grant the second DFC's Kafka user the perf-assurance **group** ACL (§6.5). For
one-at-a-time operation, one DFC plus the `DATA_TYPE_FORMAT` convergence (§6.6,
Option B) is cleanest.

Backups taken before repointing `dfc` (rollback safety):

```bash
kubectl -n smo get statefulset dfc -o yaml > ~/dfc-BACKUP-$(date +%F-%H%M).yaml
# restore: kubectl apply -f ~/dfc-BACKUP-....yaml
```

---

## 9. Quick reference — all verification commands

```bash
# ---- hop 2: topic has OAI fileReady ----
kubectl -n onap get pods | grep -iE 'strimzi.*broker'

# ---- hop 3: DFC collect + SFTP + store ----
kubectl -n smo logs dfc-0 -c dfc -f | grep -iE 'Listening|TS28532|Download|Stored'

# ---- hop 4: converter output size (must be >23B) ----
kubectl -n smo exec kafka-producer-pm-xml2json-0 -- printenv DATA_TYPE_FORMAT
kubectl -n smo exec minio-0 -c minio -- sh -c \
 'mc alias set local http://localhost:9000 admin adminadmin 2>/dev/null; mc ls local/pm-files-json/oai-gnb-mono/ | tail -3'

# ---- hop 5: producer delivers to pmreports ----
kubectl -n smo logs pm-producer-json2kafka-0 -c pm-producer-json2kafka --tail=30 | grep -viE 'OAuth|callback|Sasl'

# ---- hop 6: pmlog writes InfluxDB ----
kubectl -n smo logs pmlog-0 -c pmlog -f | grep -iE 'InfluxStore|Processed file|Stored data|Token validation'

# ---- kafka user ACLs (perf-assurance topic+group) ----
kubectl -n onap get kafkauser service-account-dfc -o yaml | sed -n '/authorization/,/status/p'

# ---- pod health ----
kubectl -n smo get pods | grep -iE 'dfc|xml2json|pm-producer|pmlog|minio|influx'
```

**InfluxDB Flux (UI `http://192.168.8.69:30138`, org `ravi-ric`):**

```flux
from(bucket: "ran-pm-metrics")
  |> range(start: -30m)
  |> filter(fn: (r) => r._measurement =~ /DuFunction=3602/)
  |> last()
```

---

## 10. Summary

The OAI PM path is complete and verified end to end:

```
OAI gNB --o1 stats--> O1 Adapter --32.435 measCollecFile + TS28532 fileReady-->
VES --stndDefined routing--> Kafka(SEC_3GPP_PERFORMANCEASSURANCE_OUTPUT) -->
DFC --SFTP pull--> MinIO(ropfiles) --collected-file--> pm-file-converter
  (DATA_TYPE_FORMAT="" -> measCollecFile) --> MinIO(pm-files-json) -->
pm-producer(ICS job pmreports) --pmreports--> pmlog --> InfluxDB(ran-pm-metrics)
```

The four fixes that made it work, in the order they mattered: rebuild the RANPM
images around the nexus3 `402` (§6.1) and side-load via `ctr import` around the
registry `401` (§6.2); correct the jar-directory packaging bug (§6.3); refresh
the stale Keycloak tokens (§6.4); add the Kafka consumer-group ACL (§6.5); and —
the decisive one — set `DATA_TYPE_FORMAT=""` so the converter parses OAI's
`measCollecFile` instead of `measDataFile` (§6.6).

For durable both-gNB operation without per-session toggling, converge OCUDU's PM
XML to `measCollecFile` (§6.6 Option B); after that a single DFC and a single
converter setting serve both gNBs, with InfluxDB keeping them apart by FDN.!



![alt text](<../resources/DL tput.png>)

![alt text](../resources/DL-UL.png)