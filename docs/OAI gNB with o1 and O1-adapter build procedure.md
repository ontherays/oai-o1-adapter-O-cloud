# Comprehensive Build Protocol: OAI O1-Adapter & O1/E2-Capable gNB

This guide provides a practical build and deployment procedure for the OAI O1-Adapter and an O1/E2-capable OAI gNB. It covers native compilation, Docker-based builds, OAI FHI 7.2 integration, optional **OSC NEAR RT RIC** E2 Agent configuration, and runtime verification.

---

## 1. Architecture

The OAI O1-Adapter provides the management interface between an OAI softmodem and an O-RAN SMO. It uses NETCONF/YANG for management operations and communicates with the OAI softmodem through its Telnet interface.

The main components are:

* **Netopeer2-server** — provides the NETCONF server.
* **Sysrepo** — provides the YANG-based configuration datastore.
* **O1 Adapter** — processes O1 management data and translates it to the OAI softmodem interface.
* **Telnet client** — communicates with the OAI softmodem.
* **VES** — handles VES notifications.
* **FTP server** — provides the interface used for PM data.
* **O-RAN-SC SMO** — provides the NETCONF client, VES collector, and PM collector.

### 1.1 High-Level Architecture

![alt text](resources/oai-o1-adapter.png)

The O1 Adapter separates the standardized O-RAN O1 management interface from the OAI gNB's internal Telnet interface.

---

## 2. Fetch the O1-Adapter Source

Clone the O1-Adapter repository into a local workspace:

```bash
git clone https://gitlab.eurecom.fr/oai/o1-adapter.git oai-o1-adapter
cd oai-o1-adapter

chmod -R +x .
```

Verify the repository:

```bash
git status
git remote -v
```

The O1-Adapter source is distributed under the Collaborative Standards Software License (CSSL) v1.0.

---

# 3. Native Build

Native compilation can be used when the adapter is deployed directly on the host without Docker.

The build requires NETCONF and YANG components including:

* `libyang`
* `sysrepo`
* `libssh`
* `libnetconf2`
* `netopeer2`
* `cjson`
* `curl`
* Telnet support
* Standard build tools

The exact dependency versions depend on the O1-Adapter revision and the host operating system.

## 3.1 Install Build Dependencies

```bash
sudo apt-get update
sudo apt-get upgrade

sudo apt-get install -y \
  tzdata \
  build-essential \
  git \
  cmake \
  pkg-config \
  unzip \
  wget \
  libpcre2-dev \
  zlib1g-dev \
  libssl-dev \
  autoconf \
  libtool
```

Install the NETCONF-related packages:

```bash
sudo apt-get install -y \
  --no-install-recommends \
  psmisc \
  unzip \
  wget \
  openssl \
  openssh-client \
  vsftpd \
  openssh-server
```

## 3.2 Create the NETCONF User

Create the required system user:

```bash
sudo adduser --system netconf
sudo passwd netconf
```

For environments using predefined credentials, configure the corresponding NETCONF username and password according to the deployment environment.

## 3.3 Install NETCONF Dependencies

From the O1-Adapter repository:

```bash
cd <WORKSPACE>/oai-o1-adapter

./scripts/netconf_dep_install.sh
sudo ldconfig
```

This installs the required NETCONF dependency chain, including:

* libssh
* libyang
* sysrepo
* libnetconf2
* netopeer2

## 3.4 Configure Netopeer2

Configure the Netopeer2 host key and server configuration:

```bash
sudo /usr/local/share/netopeer2/merge_hostkey.sh
sudo /usr/local/share/netopeer2/merge_config.sh
```

## 3.5 Retrieve and Install YANG Models

Retrieve the required O1 YANG models:

```bash
cd <WORKSPACE>/oai-o1-adapter

./docker/scripts/get-yangs.sh
./docker/scripts/install-yangs.sh
```

The YANG models provide the schema used by the NETCONF and Sysrepo management plane.

## 3.6 Build the Adapter

Compile the adapter:

```bash
cd <WORKSPACE>/oai-o1-adapter/src

./build.sh
```

Verify the generated files:

```bash
ls -lh
```


```markdown


## 3.7 Automated Native Build

The complete native build is automated by:

```bash
scripts/native_build.sh

```

Run the script from the directory containing the O1-Adapter source:

```bash
sudo ./scripts/native_build.sh

```

The script performs the following operations:

* Installs the required system and build packages.
* Creates the `netconf` system user.
* Retrieves the O1-Adapter source if it is not already available.
* Installs NETCONF dependencies including `libssh`, `libyang`, `sysrepo`, and `Netopeer2`.
* Configures `Netopeer2`.
* Retrieves and installs the required O1 YANG models.
* Builds the O1-Adapter binary.

After a successful build, the adapter binary is available under:

```text
oai-o1-adapter/src/

```

---

# 4. Native Runtime

The native O1 deployment requires the NETCONF server and the O1 Adapter to run simultaneously.

## 4.1 Start Netopeer2

Start the NETCONF server with the extended request timeout:

```bash
netopeer2-server -d -t 60
```

The `-t 60` option provides a longer timeout for requests that require additional processing time.

The exact command may vary depending on the installed Netopeer2 version.

## 4.2 Start the O1 Adapter

Set the terminal environment:

```bash
export TERM=xterm-256color
```

Start the adapter:

```bash
./gnb-adapter
```

The adapter communicates with the OAI softmodem through the Telnet interface.


## 4.3 Automated Docker Build

The complete Docker build is automated by:

```bash
scripts/docker_ci_build.sh
```

The script builds:

```text
O1-Adapter image
        │
        ▼
OAI FHI 7.2 O1-capable gNB image
```

Run:

```bash
./scripts/docker_ci_build.sh
```

The script performs the following operations:

* Clones the O1-Adapter source when required.
* Builds the O1-Adapter Docker image.
* Verifies that the OAI gNB source is available.
* Checks out the configured OAI release.
* Patches `Dockerfile.gNB.fhi72.ubuntu`.
* Adds the required Telnet libraries, including:
  * `libtelnetsrv.so`
  * `libtelnetsrv_ci.so`
  * `libtelnetsrv_o1.so`
* Adds a build-time check for `libtelnetsrv_o1.so`.
* Builds the `oai-gnb` runtime image.
* Verifies the Telnet libraries inside the resulting image.

The resulting images follow the general naming pattern:

```text
<REGISTRY_HOST>/<REGISTRY_NAMESPACE>/oai-o1-adapter:<IMAGE_TAG>
<REGISTRY_HOST>/<REGISTRY_NAMESPACE>/oai-gnb-fhi72:<OAI_VERSION>-o1
```



---

# 5. Docker Build

Docker provides a self-contained build environment and is suitable for reproducible deployments and CI/CD pipelines.

## 5.1 Build Using the Repository Wrapper

The repository provides `build-adapter.sh` for building the adapter image.

Run:

```bash
./build-adapter.sh --adapter
```

Verify the generated image:

```bash
docker images | grep -i adapter
```

The local image is typically generated with a tag similar to:

```text
adapter-gnb:latest
```

The exact tag depends on the repository revision and build script.

---

## 5.2 Tag and Push the Adapter Image

For a private or external container registry, use the registry and namespace applicable to the target deployment.

```bash
export REGISTRY_HOST="<REGISTRY_HOST>"
export REGISTRY_NAMESPACE="<REGISTRY_NAMESPACE>"
export IMAGE_TAG="<IMAGE_TAG>"
```

Tag the image:

```bash
docker tag adapter-gnb:latest \
  "${REGISTRY_HOST}/${REGISTRY_NAMESPACE}/oai-o1-adapter:${IMAGE_TAG}"
```

Authenticate with the registry:

```bash
docker login "${REGISTRY_HOST}"
```

Push the image:

```bash
docker push \
  "${REGISTRY_HOST}/${REGISTRY_NAMESPACE}/oai-o1-adapter:${IMAGE_TAG}"
```

The resulting image follows the general naming convention:

```text
<REGISTRY_HOST>/<REGISTRY_NAMESPACE>/oai-o1-adapter:<IMAGE_TAG>
```

---

# 6. Direct Docker Build

For CI/CD environments requiring deterministic image tags, the adapter can be built directly from its Dockerfile.

From the repository root:

```bash
docker build \
  -f docker/Dockerfile.adapter \
  -t "${REGISTRY_HOST}/${REGISTRY_NAMESPACE}/oai-o1-adapter:${IMAGE_TAG}" \
  .
```

The build requires network access to the upstream repositories used by the dependency and YANG retrieval scripts.

Relevant scripts include:

```text
scripts/netconf_dep_install.sh
docker/scripts/get-yangs.sh
docker/scripts/install-yangs.sh
```

If the build fails while retrieving dependencies or YANG models, inspect the upstream URLs referenced by these scripts.

---

# 7. O1-Capable OAI gNB Build — FHI 7.2

A functional O1 interface requires:

1. The O1 Adapter.
2. An OAI gNB build containing the required O1 Telnet module.

The FHI 7.2 build may generate the required Telnet libraries during the build stage, while the final runtime image may not automatically contain all of them.

The O1 library must therefore be explicitly included in the runtime image.

---

## 7.1 Update the OAI gNB Dockerfile

Open:

```text
docker/Dockerfile.gNB.fhi72.ubuntu
```

Locate the `COPY --from=gnb-build ... /usr/local/lib` section.

Ensure the required Telnet libraries are included:

```dockerfile
    /oai-ran/cmake_targets/ran_build/build/libtelnetsrv.so \
    /oai-ran/cmake_targets/ran_build/build/libtelnetsrv_ci.so \
    /oai-ran/cmake_targets/ran_build/build/libtelnetsrv_o1.so \
```

The important O1-specific library is:

```text
libtelnetsrv_o1.so
```

The standard Telnet server library alone does not provide the O1 integration required by the adapter.

---

# 8. Build the OAI FHI 7.2 O1 Image

From the OAI source directory:

```bash
cd <OAI_SOURCE_DIR>

docker build \
  --target oai-gnb \
  --tag "${REGISTRY_HOST}/${REGISTRY_NAMESPACE}/oai-gnb-fhi72:<OAI_VERSION>-o1" \
  --file docker/Dockerfile.gNB.fhi72.ubuntu \
  .
```

The resulting image follows the general naming convention:

```text
<REGISTRY_HOST>/<REGISTRY_NAMESPACE>/oai-gnb-fhi72:<OAI_VERSION>-o1
```

---

# 9. Verify the O1 Libraries

The OAI runtime image may define an `ENTRYPOINT`. Override it when inspecting the image:

```bash
docker run --rm \
  --entrypoint bash \
  "${REGISTRY_HOST}/${REGISTRY_NAMESPACE}/oai-gnb-fhi72:<OAI_VERSION>-o1" \
  -lc "ldconfig -p | grep -i telnet"
```

The output should include:

```text
libtelnetsrv.so
libtelnetsrv_ci.so
libtelnetsrv_o1.so
```

The libraries should resolve to the runtime library directory.

They can also be checked directly:

```bash
docker run --rm \
  --entrypoint bash \
  "${REGISTRY_HOST}/${REGISTRY_NAMESPACE}/oai-gnb-fhi72:<OAI_VERSION>-o1" \
  -lc "ls -lh /usr/local/lib/libtelnetsrv*"
```

---

# 10. Optional OSC NEAR RT RIC E2 Agent Configuration

If the OAI gNB also needs to connect to an OSC Near-RT RIC through E2, configure the E2 Agent before building the final gNB image.

The E2 configuration depends on the target Near-RT RIC deployment.

## 10.1 Configure the E2T SCTP Port

Use the SCTP port configured by the target RIC:

```text
<RIC_E2_SCTP_PORT>
```

Locate:

```text
openair2/E2AP/flexric/src/agent/e2_agent_api.c
```

If the selected OAI source revision uses a compile-time E2 port definition:

```c
#define E2_AGENT_PORT <RIC_E2_SCTP_PORT>
```

## 10.2 Rebuild the gNB

Rebuild the FHI 7.2 build stage followed by the final OAI gNB image.

The resulting image can use:

```text
<REGISTRY_HOST>/<REGISTRY_NAMESPACE>/oai-gnb-fhi72:<OAI_VERSION>-o1-e2
```

---

# 11. Runtime Configuration

The O1 Adapter configuration controls the connection between the adapter, the OAI gNB, and the O1 management services.

The configuration includes parameters for:

* NETCONF connectivity
* Telnet connectivity
* Performance Data
* VES notifications
* Telnet-to-gNB mapping
* O1 management operations

For detailed configuration parameters, refer to the upstream OAI O1-Adapter documentation:

[OAI O1-Adapter — How to connect via O1](https://gitlab.eurecom.fr/oai/o1-adapter/-/blob/main/README.md?ref_type=heads#how-to-connect-via-o1)

---

# 12. Docker Compose Deployment

Docker Compose can be used to deploy the adapter while mounting the runtime configuration without rebuilding the image.

Example:

```yaml
services:
  adapter-gnb:
    container_name: adapter-gnb

    image: <REGISTRY_HOST>/<REGISTRY_NAMESPACE>/oai-o1-adapter:<IMAGE_TAG>

    ports:
      - "<NETCONF_HOST_PORT>:830"
      - "<SSH_HOST_PORT>:22"

    volumes:
      - ./.ftp:/ftp
      - ./config/config.json:/adapter/config/config.json
```

The host-side ports can be selected according to the deployment environment.

---

# 13. OAI gNB Runtime Configuration

Enable the O1 Telnet server through the gNB deployment configuration.

For example:

```yaml
env:
  - name: USE_ADDITIONAL_OPTIONS
    value: "--telnetsrv --telnetsrv.shrmod o1 --telnetsrv.listenport <GNB_TELNET_PORT>"
```

The Telnet port configured here must correspond to the port configured in the O1 Adapter.

---

# 14. Adapter-to-gNB Telnet Configuration

The O1 Adapter communicates with the OAI gNB through Telnet.

The two configurations must use the same port:

```text
O1 Adapter
    |
    | Telnet
    | <GNB_TELNET_PORT>
    v
OAI gNB
```

The adapter configuration:

```text
telnet.port
```

must match the gNB runtime option:

```text
--telnetsrv.listenport <GNB_TELNET_PORT>
```

A mismatch prevents the adapter from communicating with the gNB.

---

# 15. Verification

Verify each component independently before performing the complete O1 integration.

## 15.1 Adapter Build

```bash
git status
```

For Docker deployments:

```bash
docker images | grep -i o1
```

## 15.2 O1 Adapter Components

Verify that the required components are available:

```text
gnb-adapter
netopeer2-server
sysrepo
YANG models
```

## 15.3 OAI gNB O1 Libraries

```bash
ldconfig -p | grep -i telnet
```

Expected libraries:

```text
libtelnetsrv.so
libtelnetsrv_ci.so
libtelnetsrv_o1.so
```

## 15.4 Telnet Connectivity

Verify that the gNB Telnet listener is reachable:

```bash
nc -vz <GNB_HOST> <GNB_TELNET_PORT>
```

Alternatively:

```bash
telnet <GNB_HOST> <GNB_TELNET_PORT>
```

## 15.5 NETCONF Connectivity

Verify the NETCONF endpoint:

```bash
nc -vz <ADAPTER_HOST> <NETCONF_PORT>
```

Then establish an authenticated NETCONF session using the configured NETCONF credentials.

## 15.6 E2 Connectivity

If E2 is enabled, verify connectivity to:

```text
<RIC_E2T_HOST>:<RIC_E2_SCTP_PORT>
```

using SCTP and the E2 configuration of the target Near-RT RIC.

---

# 16. Troubleshooting

## 16.1 `libtelnetsrv_o1.so` Is Missing

Check the available Telnet libraries:

```bash
ldconfig -p | grep -i telnet
```

If `libtelnetsrv_o1.so` is missing:

1. Verify that the build stage generated the library.
2. Check the `COPY --from=gnb-build` section of the Dockerfile.
3. Rebuild the runtime image.
4. Verify the library again.

---

## 16.2 Adapter Cannot Connect to the gNB

Check the gNB Telnet listener:

```bash
ss -lntp | grep <GNB_TELNET_PORT>
```

Verify that:

```text
adapter config.json
        |
        +-- telnet.port
                  |
                  | must match
                  v
gNB
        |
        +-- --telnetsrv.listenport
```

Then test network connectivity:

```bash
nc -vz <GNB_HOST> <GNB_TELNET_PORT>
```

---

## 16.3 NETCONF Connection Fails

Check that Netopeer2 is running:

```bash
ps aux | grep netopeer2
```

Check the NETCONF listening port:

```bash
ss -lntp | grep <NETCONF_PORT>
```

Check that the NETCONF user exists:

```bash
getent passwd <NETCONF_USER>
```

---

## 16.4 YANG Model Installation Fails

Run:

```bash
./docker/scripts/get-yangs.sh
./docker/scripts/install-yangs.sh
```

Check:

* Internet connectivity
* Upstream repository availability
* Git/Gerrit URLs
* YANG model versions
* libyang/sysrepo compatibility

---

## 16.5 Docker Build Fails

Check connectivity to the upstream repositories used by the build scripts:

```bash
git ls-remote <UPSTREAM_REPOSITORY>
```

Review:

```text
scripts/netconf_dep_install.sh
docker/scripts/get-yangs.sh
docker/scripts/install-yangs.sh
```

Changes in upstream repository locations or revisions may require corresponding updates to the build scripts.

---

## 16.6 E2 Connection Fails

Verify:

* E2T host
* SCTP connectivity
* E2T port
* gNB E2 Agent configuration
* Near-RT RIC E2T configuration
* Network/firewall configuration
* OAI and RIC software compatibility

---

# 17. Example Configuration

A generic adapter configuration can be represented as:

```json
{
  "host": "<GNB_HOST>",
  "telnet": {
    "port": "<GNB_TELNET_PORT>"
  },
  "netconf": {
    "host": "<ADAPTER_HOST>",
    "port": "<NETCONF_PORT>",
    "username": "<NETCONF_USER>"
  }
}
```

Replace the environment-specific values when deploying the adapter.

---

# 18. Build and Deployment Flow

The recommended sequence is:

```text
1. Clone O1-Adapter
        |
        v
2. Install dependencies
        |
        v
3. Build O1-Adapter
        |
        v
4. Install YANG models
        |
        v
5. Build OAI FHI 7.2
        |
        v
6. Include libtelnetsrv_o1.so
        |
        v
7. Build OAI gNB O1 image
        |
        +------ Optional ------+
        |                      |
        v                      v
   Configure O1          Configure E2
        |                      |
        +----------+-----------+
                   |
                   v
             Deploy gNB
                   |
                   v
            Deploy Adapter
                   |
                   v
        Verify Telnet / NETCONF
                   |
                   v
             Connect SMO
                   |
                   v
        Optional Near-RT RIC
```

---

# 19. References

* [OAI O1-Adapter](https://gitlab.eurecom.fr/oai/o1-adapter)
* [OAI O1-Adapter — How to connect via O1](https://gitlab.eurecom.fr/oai/o1-adapter/-/blob/main/README.md?ref_type=heads#how-to-connect-via-o1)
* [OpenAirInterface 5G](https://gitlab.eurecom.fr/oai/openairinterface5g)