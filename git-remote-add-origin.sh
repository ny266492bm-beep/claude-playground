#!/usr/bin/env bash
# 원격 저장소(origin) 간편 등록: GitHub 주소나 OWNER/이름만 적으면 origin으로 추가한다
# 이미 origin이 있으면 같은 주소일 때는 그대로 두고, 다른 주소면 --force 로 바꾼다.

set -euo pipefail

REMOTE="origin"
URL=""
FORCE=0

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m✔\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m✘\033[0m %s\n' "$*" >&2; exit 1; }
has()  { command -v "$1" >/dev/null 2>&1; }

usage() {
  cat <<'EOF'
사용법: git-remote-add-origin.sh <주소|OWNER/이름> [--force]

  <주소>               https://github.com/OWNER/이름 또는 git@github.com:OWNER/이름.git
  OWNER/이름           https://github.com/OWNER/이름.git 으로 바꿔서 등록
  --force              origin이 이미 다른 주소로 등록되어 있으면 새 주소로 바꿈
  -h, --help           이 도움말

예시:
  ./git-remote-add-origin.sh https://github.com/my-name/my-project
  ./git-remote-add-origin.sh my-name/my-project
  ./git-remote-add-origin.sh git@github.com:my-name/my-project.git
  ./git-remote-add-origin.sh my-name/other-project --force
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --force)   FORCE=1 ;;
    -h|--help) usage; exit 0 ;;
    -*) usage >&2; echo >&2; die "알 수 없는 옵션: $1" ;;
    *)
      [ -z "$URL" ] || die "주소는 하나만 적으세요: $URL, $1"
      URL="$1" ;;
  esac
  shift
done

[ -n "$URL" ] || { usage >&2; echo >&2; die "원격 저장소 주소를 적으세요."; }

# 주소 정리: 끝의 / 제거, OWNER/이름 → GitHub HTTPS 주소, HTTPS 주소에는 .git 을 붙인다
URL="${URL%/}"
case "$URL" in
  *://*|*@*:*|/*|./*|../*) ;;
  */*/*) die "OWNER/이름 형식이 아닙니다: $URL" ;;
  */*)   URL="https://github.com/$URL" ;;
  *)     die "주소 또는 OWNER/이름 형식으로 적으세요: $URL" ;;
esac
case "$URL" in
  http://*|https://*) URL="${URL%.git}.git" ;;
esac

has git || die "git이 설치되어 있지 않습니다."
git rev-parse --git-dir >/dev/null 2>&1 || die "git 저장소가 아닙니다. 먼저 'git init' 을 실행하세요."

CURRENT="$(git config --get "remote.$REMOTE.url" || true)"
if [ -z "$CURRENT" ]; then
  info "$REMOTE 등록: $URL"
  git remote add "$REMOTE" "$URL"
elif [ "${CURRENT%.git}" = "${URL%.git}" ]; then
  ok "$REMOTE 이(가) 이미 $CURRENT 로 등록되어 있습니다."
elif [ "$FORCE" -eq 1 ]; then
  info "$REMOTE 주소 변경: $CURRENT → $URL"
  git remote set-url "$REMOTE" "$URL"
else
  die "$REMOTE 이(가) 이미 다른 주소로 등록되어 있습니다: $CURRENT (바꾸려면 --force)"
fi

# 접속 확인: 저장소가 없거나 로그인이 안 되어 있어도 경고만 한다 (자격 증명 질문은 띄우지 않음)
if GIT_TERMINAL_PROMPT=0 git ls-remote "$REMOTE" >/dev/null 2>&1; then
  ok "$REMOTE 에 접속할 수 있습니다."
else
  warn "$REMOTE 에 접속하지 못했습니다. 저장소가 있는지(./gh-repo-create.sh), 로그인했는지(./gh-auth-login.sh) 확인하세요."
fi

BRANCH="$(git symbolic-ref --short HEAD 2>/dev/null || echo main)"
echo
git remote -v
echo
if git rev-parse --verify -q HEAD >/dev/null; then
  echo "  올리기:  git push -u $REMOTE $BRANCH"
else
  echo "  아직 커밋이 없습니다. 첫 커밋 후 올리세요:"
  echo "    git add -A"
  echo "    git commit -m \"첫 커밋\""
  echo "    git push -u $REMOTE $BRANCH"
fi
