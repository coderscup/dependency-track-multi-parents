#!/bin/bash
# This file is part of Dependency-Track.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) OWASP Foundation. All Rights Reserved.

# SessionStart hook for Claude Code on the web.
#
# Prepares the cloud container so that `make build`, `make test-single`,
# `make format-java` and `make lint-migrations` work:
#
#   * JDK 25 (the Maven enforcer requires [25,); the image ships JDK 21).
#   * A running Docker daemon (Testcontainers starts PostgreSQL for tests).
#   * Testcontainers pulls Docker Hub images via mirror.gcr.io, because
#     anonymous Docker Hub pulls are rate-limited (HTTP 429) behind the proxy.
#   * A local Squawk image, because the proxy blocks ghcr.io blob downloads.
#     Use it via `make lint-migrations SQUAWK_IMAGE=dt-local/squawk:2.63.0 AGENT=1`.
#   * `origin/main`, which `make lint-migrations` uses as BASE_REF.
#   * A warm Maven repository and build cache (`make install`, tests skipped).
#
# Idempotent: every step checks whether it is already done.

set -euo pipefail

if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

cd "${CLAUDE_PROJECT_DIR:-$(pwd)}"

log() {
  echo "[session-start] $*" >&2
}

readonly JDK_HOME=/usr/lib/jvm/java-25-openjdk-amd64
readonly SQUAWK_VERSION=2.63.0
readonly SQUAWK_LOCAL_IMAGE="dt-local/squawk:${SQUAWK_VERSION}"
readonly TEST_DB_IMAGE=mirror.gcr.io/postgres:14-alpine

# --- JDK 25 -----------------------------------------------------------------
if [ ! -x "${JDK_HOME}/bin/javac" ]; then
  log "Installing OpenJDK 25"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -q >/dev/null
  apt-get install -y -q openjdk-25-jdk-headless >/dev/null
fi
export JAVA_HOME="${JDK_HOME}"
export PATH="${JDK_HOME}/bin:${PATH}"

# --- Session environment ----------------------------------------------------
if [ -n "${CLAUDE_ENV_FILE:-}" ]; then
  {
    echo "export JAVA_HOME=${JDK_HOME}"
    echo "export PATH=${JDK_HOME}/bin:\$PATH"
    echo "export TESTCONTAINERS_HUB_IMAGE_NAME_PREFIX=mirror.gcr.io/"
    echo "export TESTCONTAINERS_RYUK_DISABLED=true"
  } >>"${CLAUDE_ENV_FILE}"
fi
export TESTCONTAINERS_HUB_IMAGE_NAME_PREFIX=mirror.gcr.io/
export TESTCONTAINERS_RYUK_DISABLED=true

# --- Docker daemon ----------------------------------------------------------
if ! docker info >/dev/null 2>&1; then
  log "Starting Docker daemon"
  setsid nohup dockerd >/tmp/dockerd.log 2>&1 </dev/null &
  for _ in $(seq 1 60); do
    docker info >/dev/null 2>&1 && break
    sleep 1
  done
fi
if ! docker info >/dev/null 2>&1; then
  log "Docker daemon did not start, see /tmp/dockerd.log. Tests will not work."
  exit 1
fi

if ! docker image inspect "${TEST_DB_IMAGE}" >/dev/null 2>&1; then
  log "Pulling ${TEST_DB_IMAGE}"
  docker pull -q "${TEST_DB_IMAGE}" >/dev/null
fi

# --- Squawk (migration linter) ----------------------------------------------
if ! command -v squawk >/dev/null 2>&1 || [ "$(squawk --version 2>/dev/null)" != "squawk ${SQUAWK_VERSION}" ]; then
  log "Installing squawk ${SQUAWK_VERSION}"
  pip install -q --root-user-action=ignore "squawk-cli==${SQUAWK_VERSION}"
fi
if ! docker image inspect "${SQUAWK_LOCAL_IMAGE}" >/dev/null 2>&1; then
  log "Building ${SQUAWK_LOCAL_IMAGE}"
  squawk_ctx="$(mktemp -d)"
  cp "$(command -v squawk)" "${squawk_ctx}/squawk"
  cat >"${squawk_ctx}/Dockerfile" <<'EOF'
FROM mirror.gcr.io/library/debian:bookworm-slim
COPY squawk /usr/local/bin/squawk
ENTRYPOINT ["/usr/local/bin/squawk"]
EOF
  docker build -q -t "${SQUAWK_LOCAL_IMAGE}" "${squawk_ctx}" >/dev/null
  rm -rf "${squawk_ctx}"
fi

# --- Spectral (OpenAPI linter) ----------------------------------------------
# Best effort: Docker Hub may answer with HTTP 429. `make lint-openapi` can then
# be run with SPECTRAL_IMAGE=mirror.gcr.io/stoplight/spectral:<version>.
spectral_image="$(sed -n 's/^SPECTRAL_IMAGE := //p' Makefile)"
if [ -n "${spectral_image}" ] && ! docker image inspect "${spectral_image}" >/dev/null 2>&1; then
  log "Pulling ${spectral_image}"
  docker pull -q "${spectral_image}" >/dev/null 2>&1 \
    || log "Could not pull ${spectral_image}. See MULTIPLE_PARENTS_HANDOFF.md for the mirror override."
fi

# --- BASE_REF for migration linting -----------------------------------------
if ! git rev-parse --verify --quiet origin/main >/dev/null; then
  log "Fetching origin/main"
  git fetch --quiet --depth=50 origin main:refs/remotes/origin/main \
    || log "Could not fetch origin/main. Pass BASE_REF explicitly to make lint-migrations."
fi

# --- Warm Maven repository and build cache ----------------------------------
log "Warming Maven repository (make install, tests skipped)"
make install AGENT=1 >/tmp/session-start-maven.log 2>&1 \
  || log "make install failed, see /tmp/session-start-maven.log"

log "Done"
