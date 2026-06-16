#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ZIG_VERSION="${ZIG_VERSION:-0.15.2}"
GO_VERSION="${GO_VERSION:-1.24.0}"
NODE_MAJOR="${NODE_MAJOR:-24}"
JAVA_MAJOR="${JAVA_MAJOR:-21}"
DOTNET_INSTALL_DIR="${DOTNET_INSTALL_DIR:-/opt/dotnet}"

usage() {
  cat <<'EOF'
Usage: scripts/setup-toolchains.sh [toolchain ...]

Installs base language/toolchain packages used by server implementation tests on Ubuntu.
When no toolchains are supplied, reads every servers/<name>/bench.json manifest.
EOF
}

log() {
  printf '[toolchains] %s\n' "$*"
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    printf '[toolchains] error: missing required command after setup: %s\n' "$1" >&2
    exit 1
  }
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi

if (( $# > 0 )); then
  TOOLCHAINS=("$@")
else
  require_command jq
  mapfile -t TOOLCHAINS < <(find servers -mindepth 2 -maxdepth 2 -name bench.json -print0 | xargs -0 jq -r '.toolchains[]? // empty' | sort -u)
fi

(( ${#TOOLCHAINS[@]} > 0 )) || exit 0

if ! command -v apt-get >/dev/null 2>&1; then
  log "non-apt host detected; skipping automatic setup for: ${TOOLCHAINS[*]}"
  exit 0
fi

apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y curl ca-certificates git build-essential jq procps unzip xz-utils pkg-config

install_apt_once() {
  DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
}

install_node() {
  if command -v node >/dev/null 2>&1; then return; fi
  curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash -
  install_apt_once nodejs
}

install_go() {
  if command -v go >/dev/null 2>&1; then return; fi
  curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz" -o /tmp/go.tar.gz
  rm -rf /usr/local/go
  tar -C /usr/local -xzf /tmp/go.tar.gz
  ln -sf /usr/local/go/bin/go /usr/local/bin/go
  ln -sf /usr/local/go/bin/gofmt /usr/local/bin/gofmt
}

install_bun() {
  if command -v bun >/dev/null 2>&1; then return; fi
  install -d -m 755 /opt/bun
  curl -fsSL https://bun.sh/install | BUN_INSTALL=/opt/bun bash
  ln -sf /opt/bun/bin/bun /usr/local/bin/bun
}

install_rust() {
  if command -v cargo >/dev/null 2>&1; then return; fi
  curl -fsSL https://sh.rustup.rs -o /tmp/rustup.sh
  sh /tmp/rustup.sh -y --profile minimal --default-toolchain stable
  ln -sf /root/.cargo/bin/cargo /usr/local/bin/cargo || true
  ln -sf /root/.cargo/bin/rustc /usr/local/bin/rustc || true
}

install_zig() {
  if command -v zig >/dev/null 2>&1; then return; fi
  curl -fsSL "https://ziglang.org/download/${ZIG_VERSION}/zig-x86_64-linux-${ZIG_VERSION}.tar.xz" -o /tmp/zig.tar.xz
  rm -rf /opt/zig
  mkdir -p /opt/zig
  tar -C /opt/zig --strip-components=1 -xf /tmp/zig.tar.xz
  ln -sf /opt/zig/zig /usr/local/bin/zig
}

install_dotnet() {
  if command -v dotnet >/dev/null 2>&1; then return; fi
  curl -fsSL https://dot.net/v1/dotnet-install.sh -o /tmp/dotnet-install.sh
  bash /tmp/dotnet-install.sh --channel 8.0 --install-dir "$DOTNET_INSTALL_DIR"
  ln -sf "$DOTNET_INSTALL_DIR/dotnet" /usr/local/bin/dotnet
}

install_java() {
  install_apt_once "openjdk-${JAVA_MAJOR}-jdk"
  local java_home="/usr/lib/jvm/java-${JAVA_MAJOR}-openjdk-amd64"
  if [[ -x "$java_home/bin/java" && -x "$java_home/bin/javac" ]]; then
    update-alternatives --set java "$java_home/bin/java"
    update-alternatives --set javac "$java_home/bin/javac"
  fi
}

for toolchain in "${TOOLCHAINS[@]}"; do
  case "$toolchain" in
    ada) install_apt_once gnat gprbuild libgnatcoll-dev ;;
    bun) install_bun ;;
    c) install_apt_once libmicrohttpd-dev libjansson-dev ;;
    cpp) install_apt_once libboost-dev nlohmann-json3-dev ;;
    csharp) install_dotnet ;;
    go) install_go ;;
    java) install_java ;;
    node) install_node ;;
    python) install_apt_once python3 python3-pip python3-venv ;;
    ruby) install_apt_once ruby ruby-webrick ;;
    rust) install_rust ;;
    zig) install_zig ;;
    *) printf '[toolchains] error: unknown toolchain: %s\n' "$toolchain" >&2; exit 1 ;;
  esac
done

export PATH="/root/.cargo/bin:/usr/local/go/bin:/opt/bun/bin:${DOTNET_INSTALL_DIR}:$PATH"

for toolchain in "${TOOLCHAINS[@]}"; do
  case "$toolchain" in
    ada) require_command gprbuild ;;
    bun) require_command bun ;;
    c) require_command cc ; require_command pkg-config ;;
    cpp) require_command c++ ; require_command pkg-config ;;
    csharp) require_command dotnet ;;
    go) require_command go ;;
    java) require_command java ; require_command javac ;;
    node) require_command node ;;
    python) require_command python3 ;;
    ruby) require_command ruby ;;
    rust) require_command cargo ;;
    zig) require_command zig ;;
  esac
done
