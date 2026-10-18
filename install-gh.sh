#!/usr/bin/env bash
# GitHub CLI(gh) 설치 / 업데이트 / 제거 스크립트 (macOS, Linux, WSL)
# 공식 문서: https://github.com/cli/cli#installation

set -euo pipefail

REPO="cli/cli"
LOCAL_BIN="$HOME/.local/bin"
LOCAL_MAN="$HOME/.local/share/man/man1"

METHOD="auto"     # auto | brew | pkg | binary
ACTION="install"  # install | update | uninstall
TARGET=""         # 비어 있으면 최신, 또는 2.102.0 같은 버전 (binary 방식만)
LOGIN=0
WORKDIR=""

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m✔\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m✘\033[0m %s\n' "$*" >&2; exit 1; }
has()  { command -v "$1" >/dev/null 2>&1; }

cleanup() { if [ -n "$WORKDIR" ]; then rm -rf "$WORKDIR"; fi; }
trap cleanup EXIT

usage() {
  cat <<'EOF'
사용법: install-gh.sh [방식] [버전] [동작] [--login]

  (인자 없음)          자동 선택: Homebrew → 시스템 패키지 관리자(Linux) → 바이너리
  2.102.0              특정 버전 설치 (바이너리 방식으로 설치됨)

방식:
  --brew               Homebrew (brew install gh)
  --pkg                Linux 패키지 관리자 + GitHub 공식 저장소 (apt, dnf, yum, zypper, pacman, apk)
  --binary             GitHub 릴리스에서 받아 ~/.local/bin 에 설치 (sudo 불필요, 체크섬 검증)

동작:
  --update             현재 설치된 방식에 맞게 업데이트
  --uninstall          찾을 수 있는 모든 설치 제거 (설정 ~/.config/gh 는 유지)
  --login              설치 후 바로 'gh auth login' 실행
  -h, --help           이 도움말

예시:
  ./install-gh.sh
  ./install-gh.sh --login
  ./install-gh.sh --binary 2.102.0
  ./install-gh.sh --update
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --brew)      METHOD="brew" ;;
    --pkg)       METHOD="pkg" ;;
    --binary)    METHOD="binary" ;;
    --update)    ACTION="update" ;;
    --uninstall) ACTION="uninstall" ;;
    --login)     LOGIN=1 ;;
    -h|--help)   usage; exit 0 ;;
    v[0-9]*.[0-9]*.[0-9]*|[0-9]*.[0-9]*.[0-9]*) TARGET="${1#v}" ;;
    *) usage >&2; echo >&2; die "알 수 없는 인자: $1" ;;
  esac
  shift
done

OS="$(uname -s)"
case "$OS" in
  Darwin|Linux) ;;
  MINGW*|MSYS*|CYGWIN*)
    die "Windows에서는 PowerShell에서 실행하세요: winget install --id GitHub.cli" ;;
  *) die "지원하지 않는 OS입니다: $OS" ;;
esac

if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ]; then
  die "sudo 없이 실행하세요. 필요한 단계에서만 스크립트가 sudo를 호출합니다."
fi

if [ "$(id -u)" -eq 0 ]; then SUDO=""; else SUDO="sudo"; fi

need_sudo() {
  [ -z "$SUDO" ] || has sudo || die "sudo가 필요합니다. --binary 로 sudo 없이 설치할 수 있습니다."
}

# ~/.local/bin 이 PATH에 없으면 셸 설정 파일에 추가
ensure_path() {
  case ":$PATH:" in *":$LOCAL_BIN:"*) return 0 ;; esac
  export PATH="$LOCAL_BIN:$PATH"

  local rc
  case "$(basename "${SHELL:-}")" in
    zsh)  rc="$HOME/.zshrc" ;;
    bash) if [ "$OS" = "Darwin" ]; then rc="$HOME/.bash_profile"; else rc="$HOME/.bashrc"; fi ;;
    fish) warn "fish 셸: 'fish_add_path $LOCAL_BIN' 을 실행하세요."; return 0 ;;
    *)    rc="$HOME/.profile" ;;
  esac

  if ! grep -qsF ".local/bin" "$rc"; then
    printf '\n# GitHub CLI\nexport PATH="$HOME/.local/bin:$PATH"\n' >> "$rc"
    ok "PATH 설정을 $rc 에 추가했습니다."
  fi
  warn "새 터미널을 열거나 'source $rc' 를 실행해야 gh 명령을 쓸 수 있습니다."
}

pkg_manager() {
  local m
  for m in apt-get dnf yum zypper pacman apk; do
    if has "$m"; then echo "$m"; return; fi
  done
  echo "none"
}

# 현재 PATH에서 잡히는 gh가 어떤 방식으로 설치됐는지 판별
detect_method() {
  local bin real
  bin="$(command -v gh 2>/dev/null)" || { echo "none"; return; }
  real="$(readlink -f "$bin" 2>/dev/null || echo "$bin")"
  case "$real" in
    "$LOCAL_BIN/gh") echo "binary" ;;
    */Cellar/gh/*)   echo "brew" ;;
    /usr/bin/gh)     echo "pkg" ;;
    *)               echo "unknown" ;;
  esac
}

resolve_auto() {
  if [ -n "$TARGET" ]; then
    echo "binary"
  elif has brew; then
    echo "brew"
  elif [ "$OS" = "Linux" ] && [ "$(pkg_manager)" != "none" ] && { [ -z "$SUDO" ] || has sudo; }; then
    echo "pkg"
  else
    echo "binary"
  fi
}

installed_version() {
  "$1" --version 2>/dev/null | awk 'NR==1 {print $3}'
}

latest_version() {
  # API 대신 리다이렉트를 따라가서 태그를 얻는다 (API 요청 제한 회피)
  local url
  url="$(curl -fsSLI -o /dev/null -w '%{url_effective}' "https://github.com/$REPO/releases/latest")" \
    || die "최신 버전을 확인하지 못했습니다. 네트워크를 확인하세요."
  echo "${url##*/v}"
}

sha256() {
  if has sha256sum; then sha256sum "$1"; else shasum -a 256 "$1"; fi | awk '{print $1}'
}

install_brew() {
  has brew || die "Homebrew가 없습니다. https://brew.sh 에서 설치하거나 --binary 로 실행하세요."
  [ -z "$TARGET" ] || die "Homebrew는 특정 버전 설치를 지원하지 않습니다. --binary 를 쓰세요."
  info "Homebrew 설치: gh"
  brew install gh
}

install_pkg() {
  [ "$OS" = "Linux" ] || die "--pkg 는 Linux 전용입니다. macOS에서는 --brew 또는 --binary 를 쓰세요."
  [ -z "$TARGET" ] || die "패키지 관리자 설치는 특정 버전을 지원하지 않습니다. --binary 를 쓰세요."
  need_sudo

  local pm keyring="/etc/apt/keyrings/githubcli-archive-keyring.gpg"
  pm="$(pkg_manager)"
  case "$pm" in
    apt-get)
      info "apt: GitHub 공식 저장소 추가 후 설치"
      has curl || { $SUDO apt-get update && $SUDO apt-get install -y curl; }
      $SUDO mkdir -p -m 755 /etc/apt/keyrings
      curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | $SUDO tee "$keyring" >/dev/null
      $SUDO chmod go+r "$keyring"
      echo "deb [arch=$(dpkg --print-architecture) signed-by=$keyring] https://cli.github.com/packages stable main" \
        | $SUDO tee /etc/apt/sources.list.d/github-cli.list >/dev/null
      $SUDO apt-get update
      $SUDO apt-get install -y gh ;;
    dnf|yum)
      info "$pm: GitHub 공식 저장소 추가 후 설치"
      curl -fsSL https://cli.github.com/packages/rpm/gh-cli.repo | $SUDO tee /etc/yum.repos.d/gh-cli.repo >/dev/null
      # Fedora 기본 저장소에도 gh가 있으므로 dnf는 공식 저장소를 지정 (구형 yum은 --repo 미지원)
      if [ "$pm" = "dnf" ]; then $SUDO dnf install gh --repo gh-cli; else $SUDO yum install gh; fi ;;
    zypper)
      info "zypper: GitHub 공식 저장소 추가 후 설치"
      curl -fsSL https://cli.github.com/packages/rpm/gh-cli.repo | $SUDO tee /etc/zypp/repos.d/gh-cli.repo >/dev/null
      $SUDO zypper refresh gh-cli
      $SUDO zypper install gh ;;
    pacman)
      info "pacman: github-cli 설치"
      $SUDO pacman -S --needed github-cli ;;
    apk)
      info "apk: github-cli 설치"
      $SUDO apk add github-cli ;;
    *)
      die "지원하는 패키지 관리자를 찾지 못했습니다. --binary 로 실행하세요." ;;
  esac
}

install_binary() {
  has curl || die "curl이 필요합니다."

  local ver os arch ext name base expected actual current
  ver="${TARGET:-$(latest_version)}"

  if [ -x "$LOCAL_BIN/gh" ]; then
    current="$(installed_version "$LOCAL_BIN/gh")"
    if [ "$current" = "$ver" ]; then
      ok "gh $ver 이(가) 이미 설치되어 있습니다."
      ensure_path
      return 0
    fi
  fi

  case "$OS" in
    Darwin) os="macOS"; ext="zip"; has unzip || die "unzip이 필요합니다." ;;
    Linux)  os="linux"; ext="tar.gz" ;;
  esac
  case "$(uname -m)" in
    x86_64|amd64)  arch="amd64" ;;
    arm64|aarch64) arch="arm64" ;;
    armv6l|armv7l) arch="armv6" ;;
    i386|i686)     arch="386" ;;
    *) die "지원하지 않는 아키텍처입니다: $(uname -m)" ;;
  esac

  name="gh_${ver}_${os}_${arch}"
  base="https://github.com/$REPO/releases/download/v${ver}"
  WORKDIR="$(mktemp -d)"

  info "다운로드: $name.$ext"
  curl -fL --progress-bar -o "$WORKDIR/$name.$ext" "$base/$name.$ext" \
    || die "다운로드 실패. 버전($ver)이 올바른지 확인하세요: https://github.com/$REPO/releases"
  curl -fsSL -o "$WORKDIR/checksums.txt" "$base/gh_${ver}_checksums.txt" \
    || die "체크섬 파일을 받지 못했습니다."

  expected="$(awk -v f="$name.$ext" '$2 == f {print $1}' "$WORKDIR/checksums.txt")"
  actual="$(sha256 "$WORKDIR/$name.$ext")"
  [ -n "$expected" ] && [ "$expected" = "$actual" ] || die "체크섬이 일치하지 않습니다. 설치를 중단합니다."
  ok "SHA-256 체크섬 확인"

  mkdir -p "$WORKDIR/x"
  case "$ext" in
    zip)    unzip -q "$WORKDIR/$name.$ext" -d "$WORKDIR/x" ;;
    tar.gz) tar -xzf "$WORKDIR/$name.$ext" -C "$WORKDIR/x" ;;
  esac

  mkdir -p "$LOCAL_BIN" "$LOCAL_MAN"
  install -m 755 "$WORKDIR/x/$name/bin/gh" "$LOCAL_BIN/gh"
  cp "$WORKDIR/x/$name"/share/man/man1/*.1 "$LOCAL_MAN/" 2>/dev/null || true
  ok "설치: $LOCAL_BIN/gh"
  ensure_path
}

do_update() {
  case "$(detect_method)" in
    brew)
      info "Homebrew 업데이트"
      brew upgrade gh ;;
    binary)
      TARGET=""
      install_binary ;;
    pkg)
      need_sudo
      case "$(pkg_manager)" in
        apt-get) $SUDO apt-get update && $SUDO apt-get install -y --only-upgrade gh ;;
        dnf)     $SUDO dnf upgrade gh ;;
        yum)     $SUDO yum update gh ;;
        zypper)  $SUDO zypper update gh ;;
        apk)     $SUDO apk add --upgrade github-cli ;;
        pacman)  warn "Arch는 부분 업그레이드를 권장하지 않습니다. 'sudo pacman -Syu' 로 시스템 전체를 업데이트하세요." ;;
        *)       die "패키지 관리자를 찾지 못했습니다." ;;
      esac ;;
    none)
      die "설치된 gh를 찾을 수 없습니다. 먼저 설치하세요: ./install-gh.sh" ;;
    *)
      die "설치 방식을 판별하지 못했습니다 ($(command -v gh)). 설치한 방식으로 직접 업데이트하세요." ;;
  esac
}

do_uninstall() {
  local found=0

  if [ -e "$LOCAL_BIN/gh" ]; then
    info "바이너리 설치 제거"
    rm -f "$LOCAL_BIN/gh" "$LOCAL_MAN"/gh.1 "$LOCAL_MAN"/gh-*.1
    found=1
  fi

  if has brew && brew list --formula gh >/dev/null 2>&1; then
    info "Homebrew 제거: gh"
    brew uninstall gh
    found=1
  fi

  if [ "$OS" = "Linux" ]; then
    case "$(pkg_manager)" in
      apt-get) if dpkg -s gh >/dev/null 2>&1; then need_sudo; $SUDO apt-get remove -y gh; found=1; fi ;;
      dnf|yum|zypper)
        if rpm -q gh >/dev/null 2>&1; then
          need_sudo; $SUDO "$(pkg_manager)" remove gh; found=1
        fi ;;
      pacman) if pacman -Q github-cli >/dev/null 2>&1; then need_sudo; $SUDO pacman -R github-cli; found=1; fi ;;
      apk)    if apk info -e github-cli >/dev/null 2>&1; then need_sudo; $SUDO apk del github-cli; found=1; fi ;;
    esac
  fi

  if [ "$found" -eq 0 ]; then
    warn "제거할 gh 설치를 찾지 못했습니다."
    if [ "$OS" = "Darwin" ] && pkgutil --pkg-info com.github.cli >/dev/null 2>&1; then
      warn ".pkg 설치 프로그램으로 설치된 것 같습니다: sudo rm /usr/local/bin/gh && sudo pkgutil --forget com.github.cli"
    fi
  else
    ok "제거 완료. 설정(~/.config/gh)은 남겨두었습니다. 토큰까지 지우려면 제거 전에 'gh auth logout' 을 실행하세요."
  fi
}

verify() {
  hash -r
  if ! has gh; then
    warn "gh 명령을 찾을 수 없습니다. 새 터미널을 열어 'gh --version' 으로 확인하세요."
    return 0
  fi
  ok "gh $(installed_version gh)  →  $(command -v gh)"

  local count
  count="$(type -ap gh | awk '!seen[$0]++' | wc -l | tr -d ' ')"
  if [ "$count" -gt 1 ]; then
    warn "gh가 여러 곳에 설치되어 있습니다. 하나만 남기는 것을 권장합니다:"
    type -ap gh | awk '!seen[$0]++' | sed 's/^/    /' >&2
  fi

  echo
  if [ "$LOGIN" -eq 1 ]; then
    gh auth login
  elif gh auth status >/dev/null 2>&1; then
    ok "이미 GitHub에 로그인되어 있습니다. (gh auth status)"
  else
    echo "  로그인:  gh auth login"
  fi
  echo "  예시:    gh repo clone owner/repo · gh pr list · gh issue create · gh pr create"
}

case "$ACTION" in
  install)
    [ "$METHOD" = "auto" ] && METHOD="$(resolve_auto)"
    case "$METHOD" in
      brew)   install_brew ;;
      pkg)    install_pkg ;;
      binary) install_binary ;;
    esac
    verify ;;
  update)
    do_update
    verify ;;
  uninstall)
    do_uninstall ;;
esac
