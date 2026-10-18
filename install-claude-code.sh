#!/usr/bin/env bash
# Claude Code 설치 / 업데이트 / 제거 스크립트 (macOS, Linux, WSL)
# 공식 문서: https://code.claude.com/docs/en/setup

set -euo pipefail

INSTALL_URL="https://claude.ai/install.sh"
NPM_PKG="@anthropic-ai/claude-code"
LOCAL_BIN="$HOME/.local/bin"

METHOD="native"   # native | brew | npm
ACTION="install"  # install | update | uninstall
TARGET=""         # 비어 있으면 latest, 또는 stable, 또는 2.1.89 같은 버전

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m✔\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m✘\033[0m %s\n' "$*" >&2; exit 1; }
has()  { command -v "$1" >/dev/null 2>&1; }

usage() {
  cat <<'EOF'
사용법: install-claude.sh [방식] [버전] [동작]

  (인자 없음)          네이티브 설치, latest 채널 (권장, 자동 업데이트됨)
  stable               stable 채널 (약 1주 늦지만 큰 문제 있는 릴리스는 건너뜀)
  2.1.89               특정 버전 설치

방식:
  --native             공식 설치 스크립트 사용 (기본값)
  --brew               Homebrew cask (stable 또는 latest만 가능, 자동 업데이트 안 됨)
  --npm                npm 전역 설치 (Node.js 22+ 필요)

동작:
  --update             현재 설치된 방식에 맞게 업데이트
  --uninstall          찾을 수 있는 모든 설치 제거 (설정 ~/.claude 는 유지)
  -h, --help           이 도움말

예시:
  ./install-claude.sh
  ./install-claude.sh stable
  ./install-claude.sh --brew stable
  ./install-claude.sh --npm 2.1.89
  ./install-claude.sh --update
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --native)    METHOD="native" ;;
    --brew)      METHOD="brew" ;;
    --npm)       METHOD="npm" ;;
    --update)    ACTION="update" ;;
    --uninstall) ACTION="uninstall" ;;
    -h|--help)   usage; exit 0 ;;
    stable|latest) TARGET="$1" ;;
    [0-9]*.[0-9]*.[0-9]*) TARGET="$1" ;;
    *) usage >&2; echo >&2; die "알 수 없는 인자: $1" ;;
  esac
  shift
done

case "$(uname -s)" in
  Darwin|Linux) ;;
  MINGW*|MSYS*|CYGWIN*)
    die "Windows에서는 PowerShell에서 실행하세요: irm https://claude.ai/install.ps1 | iex" ;;
  *) die "지원하지 않는 OS입니다: $(uname -s)" ;;
esac

if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ]; then
  die "sudo 없이 실행하세요. Claude Code는 홈 디렉터리에 설치되며 root 권한이 필요 없습니다."
fi

# ~/.local/bin 이 PATH에 없으면 셸 설정 파일에 추가
ensure_path() {
  case ":$PATH:" in *":$LOCAL_BIN:"*) return 0 ;; esac
  export PATH="$LOCAL_BIN:$PATH"

  local rc
  case "$(basename "${SHELL:-}")" in
    zsh)  rc="$HOME/.zshrc" ;;
    bash) if [ "$(uname -s)" = "Darwin" ]; then rc="$HOME/.bash_profile"; else rc="$HOME/.bashrc"; fi ;;
    fish) warn "fish 셸: 'fish_add_path $LOCAL_BIN' 을 실행하세요."; return 0 ;;
    *)    rc="$HOME/.profile" ;;
  esac

  if ! grep -qsF ".local/bin" "$rc"; then
    printf '\n# Claude Code\nexport PATH="$HOME/.local/bin:$PATH"\n' >> "$rc"
    ok "PATH 설정을 $rc 에 추가했습니다."
  fi
  warn "새 터미널을 열거나 'source $rc' 를 실행해야 claude 명령을 쓸 수 있습니다."
}

# 현재 PATH에서 잡히는 claude가 어떤 방식으로 설치됐는지 판별
detect_method() {
  local bin real
  bin="$(command -v claude 2>/dev/null)" || { echo "none"; return; }
  real="$(readlink -f "$bin" 2>/dev/null || echo "$bin")"
  case "$real" in
    */.local/share/claude/*)        echo "native" ;;
    */Caskroom/claude-code*)        echo "brew" ;;
    */node_modules/@anthropic-ai/*) echo "npm" ;;
    *)                              echo "unknown" ;;
  esac
}

brew_installed_casks() {
  has brew || return 0
  local c
  for c in claude-code claude-code@latest; do
    if brew list --cask "$c" >/dev/null 2>&1; then echo "$c"; fi
  done
}

install_native() {
  # 채널을 생략하면 기존 설정(예: stable)을 따르므로 항상 명시적으로 넘긴다
  local target="${TARGET:-latest}"
  info "네이티브 설치: $target"
  if has curl; then
    curl -fsSL "$INSTALL_URL" | bash -s -- "$target"
  elif has wget; then
    wget -qO- "$INSTALL_URL" | bash -s -- "$target"
  else
    die "curl 또는 wget이 필요합니다."
  fi
  ensure_path
}

install_brew() {
  has brew || die "Homebrew가 없습니다. https://brew.sh 에서 설치하거나 --brew 없이 실행하세요."
  local cask
  case "${TARGET:-latest}" in
    latest) cask="claude-code@latest" ;;
    stable) cask="claude-code" ;;
    *) die "Homebrew는 특정 버전 설치를 지원하지 않습니다. stable 또는 latest를 쓰세요." ;;
  esac
  info "Homebrew 설치: $cask"
  brew install --cask "$cask"
}

install_npm() {
  has npm || die "npm이 없습니다. Node.js 22 이상을 먼저 설치하세요: https://nodejs.org"
  local major
  major="$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)"
  if [ "$major" -lt 22 ]; then
    warn "Node.js 22 이상을 권장합니다 (현재: $(node -v 2>/dev/null || echo '없음'))."
  fi
  info "npm 설치: $NPM_PKG@${TARGET:-latest}"
  npm install -g "$NPM_PKG@${TARGET:-latest}"
}

do_update() {
  case "$(detect_method)" in
    native)
      info "네이티브 설치 업데이트"
      claude update ;;
    brew)
      local c
      for c in $(brew_installed_casks); do
        info "Homebrew 업데이트: $c"
        brew upgrade --cask "$c"
      done ;;
    npm)
      info "npm 업데이트"
      npm install -g "$NPM_PKG@latest" ;;
    none)
      die "설치된 claude를 찾을 수 없습니다. 먼저 설치하세요: ./install-claude.sh" ;;
    *)
      warn "설치 방식을 판별하지 못해 'claude update' 를 실행합니다."
      claude update ;;
  esac
}

do_uninstall() {
  local found=0 c

  if [ -e "$LOCAL_BIN/claude" ] || [ -d "$HOME/.local/share/claude" ]; then
    info "네이티브 설치 제거"
    rm -f "$LOCAL_BIN/claude"
    rm -rf "$HOME/.local/share/claude"
    found=1
  fi

  for c in $(brew_installed_casks); do
    info "Homebrew 제거: $c"
    brew uninstall --cask "$c"
    found=1
  done

  if has npm && npm ls -g "$NPM_PKG" >/dev/null 2>&1; then
    info "npm 제거"
    npm uninstall -g "$NPM_PKG"
    found=1
  fi

  if [ "$found" -eq 0 ]; then
    warn "제거할 Claude Code 설치를 찾지 못했습니다."
  else
    ok "제거 완료. 설정 파일(~/.claude, ~/.claude.json)은 남겨두었습니다."
  fi
}

verify() {
  hash -r
  if ! has claude; then
    warn "claude 명령을 찾을 수 없습니다. 새 터미널을 열어 'claude --version' 으로 확인하세요."
    return 0
  fi
  ok "$(claude --version)  →  $(command -v claude)"

  local count
  count="$(type -ap claude | awk '!seen[$0]++' | wc -l | tr -d ' ')"
  if [ "$count" -gt 1 ]; then
    warn "claude가 여러 곳에 설치되어 있습니다. 하나만 남기는 것을 권장합니다:"
    type -ap claude | awk '!seen[$0]++' | sed 's/^/    /' >&2
  fi

  echo
  echo "  시작:  claude"
  echo "  점검:  claude doctor"
}

case "$ACTION" in
  install)
    case "$METHOD" in
      native) install_native ;;
      brew)   install_brew ;;
      npm)    install_npm ;;
    esac
    verify ;;
  update)
    do_update
    verify ;;
  uninstall)
    do_uninstall ;;
esac
