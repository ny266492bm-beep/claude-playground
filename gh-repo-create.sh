#!/usr/bin/env bash
# GitHub 저장소 간편 생성: 이름과 공개 범위(--private/--public)만 적으면 바로 만든다
# 그 밖의 'gh repo create' 옵션은 '--' 뒤에 적으면 그대로 넘긴다.

set -euo pipefail

NAME=""
VISIBILITY=""
EXTRA=()

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m✘\033[0m %s\n' "$*" >&2; exit 1; }
has()  { command -v "$1" >/dev/null 2>&1; }

usage() {
  cat <<'EOF'
사용법: gh-repo-create.sh <이름> --private|--public [-- gh 추가 옵션...]

  <이름>               저장소 이름 (다른 계정/조직에 만들려면 OWNER/이름)
  --private            비공개 저장소
  --public             공개 저장소
  -- ...               이후 인자는 'gh repo create' 에 그대로 전달
  -h, --help           이 도움말

예시:
  ./gh-repo-create.sh my-project --private
  ./gh-repo-create.sh --public my-project
  ./gh-repo-create.sh my-org/my-project --private
  ./gh-repo-create.sh my-project --public -- --description "설명" --clone
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --private|--public)
      [ -z "$VISIBILITY" ] || [ "$VISIBILITY" = "$1" ] || die "--private 와 --public 중 하나만 적으세요."
      VISIBILITY="$1" ;;
    -h|--help) usage; exit 0 ;;
    --) shift; EXTRA=("$@"); break ;;
    -*) usage >&2; echo >&2; die "알 수 없는 옵션: $1 (gh 옵션은 '--' 뒤에 적으세요)" ;;
    *)
      [ -z "$NAME" ] || die "저장소 이름은 하나만 적으세요: $NAME, $1"
      NAME="$1" ;;
  esac
  shift
done

[ -n "$NAME" ] || { usage >&2; echo >&2; die "저장소 이름을 적으세요."; }
[ -n "$VISIBILITY" ] || { usage >&2; echo >&2; die "--private 또는 --public 을 적으세요."; }

has gh || die "gh가 설치되어 있지 않습니다. 먼저 ./install-gh.sh 를 실행하세요."
gh auth token >/dev/null 2>&1 || die "GitHub에 로그인되어 있지 않습니다. 먼저 ./gh-auth-login.sh 를 실행하세요."

info "$NAME 저장소 생성 (${VISIBILITY#--})"
# macOS 기본 bash 3.2 에서 빈 배열을 set -u 로 펼치면 오류가 나므로 ${arr[@]+...} 형태로 쓴다
exec gh repo create "$NAME" "$VISIBILITY" ${EXTRA[@]+"${EXTRA[@]}"}
