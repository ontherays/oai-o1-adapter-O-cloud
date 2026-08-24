#!/bin/bash
# ==============================================================================
# Script: docker_ci_build.sh
# Purpose: Deterministic Docker builds for O1-Adapter and patched O1 gNB
# ==============================================================================

set -e

REGISTRY=" <REGISTRY_HOST>/<REGISTRY_NAMESPACE>"
TAG="dev-v1"
GNB_TAG="2026.w30-o1"

echo ">>> Phase 1: Building OAI O1-Adapter Image (CI-Friendly)"
if [ ! -d "oai-o1-adapter" ]; then
    git clone https://gitlab.eurecom.fr/oai/o1-adapter.git oai-o1-adapter
fi
cd oai-o1-adapter

docker build -f docker/Dockerfile.adapter -t ${REGISTRY}/oai-o1-adapter:${TAG} .
echo ">>> O1-Adapter image built: ${REGISTRY}/oai-o1-adapter:${TAG}"
cd ..

echo ">>> Phase 2: Patching and Building O1-Capable gNB"
if [ ! -d "openairinterface5g" ]; then
    echo "Error: openairinterface5g directory not found. Please clone the repo first."
    exit 1
fi
cd openairinterface5g

# Ensure we are on the correct base
git checkout 2026.w30 || echo "Already on 2026.w30 or detached HEAD"

# Patch the Dockerfile: Insert the missing O1 and CI telnet libraries
DOCKERFILE="docker/Dockerfile.gNB.fhi72.ubuntu"
echo ">>> Patching ${DOCKERFILE} to include libtelnetsrv_o1.so..."

# Use sed to add the missing lines immediately after the core telnetsrv line
sed -i '/\/oai-ran\/cmake_targets\/ran_build\/build\/libtelnetsrv.so \\/a \    /oai-ran/cmake_targets/ran_build/build/libtelnetsrv_ci.so \\\n    /oai-ran/cmake_targets/ran_build/build/libtelnetsrv_o1.so \\' ${DOCKERFILE}

# Add hard-fail check in the Dockerfile to verify the O1 lib exists
sed -i '/RUN ldconfig/i RUN test -f /usr/local/lib/libtelnetsrv_o1.so || (echo "ERROR: libtelnetsrv_o1.so missing" && exit 1)' ${DOCKERFILE}

echo ">>> Building target oai-gnb stage..."
docker build --target oai-gnb \
  --tag ${REGISTRY}/oai-gnb-fhi72:${GNB_TAG} \
  --file ${DOCKERFILE} .

echo ">>> Build complete. Verifying libraries via loader..."
docker run --rm --entrypoint bash ${REGISTRY}/oai-gnb-fhi72:${GNB_TAG} -lc "ldconfig -p | grep -i telnet"

echo ">>> Ready for push. Run 'docker push' for both images when ready."