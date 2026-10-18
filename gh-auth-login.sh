#!/usr/bin/env bash
# GitHub CLI(gh) 간편 로그인: 질문 없이 github.com + HTTPS + 브라우저 인증으로 바로 진행
# 'gh auth login' 의 선택 질문(호스트, 프로토콜, Git 인증, 인증 방식)을 모두 기본값으로 건너뛴다.

set -euo pipefail

HOST="github.com"
MODE="web"   # web | token
FORCE=0
TOKEN=""
GIT_HELPER_ADDED=0
DONE=0

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m✔\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m✘\033[0m %s\n' "$*" >&2; exit 1; }
has()  { command -v "$1" >/dev/null 2>&1; }

usage() {
  cat <<'EOF'
사용법: gh-auth-login.sh [옵션]

  (인자 없음)          브라우저로 로그인 (github.com, HTTPS, 일회용 코드 자동 복사)
                       → Enter 한 번 → 브라우저에 코드 붙여넣기(⌘V) → Authorize 하면 끝

옵션:
  --token              브라우저 대신 개인 액세스 토큰(classic)으로 로그인
                       토큰은 파이프 입력 → GH_TOKEN 환경변수 → 직접 입력(숨김) 순으로 읽음
  --host HOST          GitHub Enterprise 서버 (기본: github.com)
  --force              이미 로그인되어 있어도 다시 로그인 (토큰 갱신 / 다른 계정 추가)
  -h, --help           이 도움말

예시:
  ./gh-auth-login.sh
  ./gh-auth-login.sh --token
  pbpaste | ./gh-auth-login.sh --token
  ./gh-auth-login.sh --host github.example.com
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --token)   MODE="token" ;;
    --host)    [ $# -ge 2 ] || die "--host 뒤에 호스트 이름을 적으세요."; HOST="$2"; shift ;;
    --host=*)  HOST="${1#--host=}" ;;
    --force)   FORCE=1 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; echo >&2; die "알 수 없는 인자: $1" ;;
  esac
  shift
done

# https://github.example.com/ 처럼 적어도 호스트 이름만 남긴다
HOST="${HOST#http://}"; HOST="${HOST#https://}"; HOST="${HOST%%/*}"
[ -n "$HOST" ] || die "호스트 이름이 비어 있습니다."

has gh || die "gh가 설치되어 있지 않습니다. 먼저 ./install-gh.sh 를 실행하세요."

# 토큰 환경변수가 있으면 'gh auth login' 이 거부하므로, 값을 챙겨 두고 이 스크립트 안에서만 비운다
ENV_TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-${GH_ENTERPRISE_TOKEN:-${GITHUB_ENTERPRISE_TOKEN:-}}}}"
unset GH_TOKEN GITHUB_TOKEN GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN

HELPER_KEYS=("credential.https://$HOST.helper")
[ "$HOST" != "github.com" ] || HELPER_KEYS+=("credential.https://gist.github.com.helper")

# git 자격 증명 도우미를 미리 gh로 설정해 두면 gh가 'Authenticate Git with your GitHub credentials?'
# 를 묻지 않고, workflow 권한(.github/workflows 푸시용)도 함께 요청한다
setup_git() {
  has git || return 0
  if git config --global --get-all "${HELPER_KEYS[0]}" 2>/dev/null | grep -q 'auth git-credential'; then
    return 0
  fi
  gh auth setup-git --hostname "$HOST" --force
  GIT_HELPER_ADDED=1
}

# 로그인이 실패하거나 중단되면 이 스크립트가 추가한 git 설정만 되돌린다
rollback_git() {
  [ "$GIT_HELPER_ADDED" -eq 1 ] || return 0
  local key
  for key in "${HELPER_KEYS[@]}"; do
    git config --global --unset-all "$key" 2>/dev/null || true
  done
}

on_exit() { if [ "$DONE" -eq 0 ]; then rollback_git; fi; }
trap on_exit EXIT
trap 'echo; exit 130' INT TERM HUP

read_token() {
  if [ ! -t 0 ]; then
    TOKEN="$(cat)"
  elif [ -n "$ENV_TOKEN" ]; then
    info "환경변수의 토큰을 사용합니다."
    TOKEN="$ENV_TOKEN"
  else
    echo "토큰 발급 (repo, read:org, gist, workflow 권한이 미리 체크된 페이지):"
    echo "  https://$HOST/settings/tokens/new?scopes=repo,read:org,gist,workflow&description=gh-cli"
    echo
    read -rsp "토큰 붙여넣기 (화면에 표시되지 않음): " TOKEN
    echo
  fi
  TOKEN="$(printf '%s' "$TOKEN" | tr -d '[:space:]')"
  [ -n "$TOKEN" ] || die "토큰이 비어 있습니다."
}

if [ "$FORCE" -eq 0 ] && gh auth status --hostname "$HOST" >/dev/null 2>&1; then
  gh auth status --hostname "$HOST"
  echo
  ok "이미 로그인되어 있습니다. 다시 로그인하거나 다른 계정을 추가하려면 --force 를 붙이세요."
  exit 0
fi

if [ "$MODE" = "token" ]; then
  read_token
  setup_git
  info "$HOST 에 토큰으로 로그인"
  printf '%s\n' "$TOKEN" | gh auth login --hostname "$HOST" --git-protocol https --with-token \
    || die "로그인하지 못했습니다. 토큰과 권한(repo, read:org)을 확인하세요."
else
  args=(--hostname "$HOST" --git-protocol https --web)
  if has pbcopy || has wl-copy || has xclip || has xsel; then
    args+=(--clipboard)
  fi
  setup_git
  info "$HOST 에 브라우저로 로그인"
  gh auth login "${args[@]}" || die "로그인하지 못했습니다."
fi

DONE=1
echo
gh auth status --hostname "$HOST"
echo
ok "로그인 완료. git push/pull 도 이 계정으로 인증됩니다."

if [ -n "$ENV_TOKEN" ] && [ "$ENV_TOKEN" != "$TOKEN" ]; then
  warn "GH_TOKEN(또는 GITHUB_TOKEN) 환경변수가 설정되어 있으면 방금 저장한 로그인보다 그 값이 우선합니다."
  warn "필요 없다면 셸 설정 파일에서 지우세요."
fi
