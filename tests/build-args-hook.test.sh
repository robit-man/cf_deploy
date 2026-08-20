#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

# Load function definitions without running vox's command dispatcher.
# shellcheck source=/dev/null
source <(sed '/# COMMAND DISPATCHER/,$d' "$repo_root/vox")

test_root=$(mktemp -d)
trap 'rm -rf "$test_root"' EXIT

WORK_DIR="$test_root/deployment"
VOX_DIR=".vox"
REPO_PATH="$test_root/application"
# compose_build (loaded dynamically above) consumes this variable.
# shellcheck disable=SC2034
COMPOSE_CMD="fake_compose"
capture_file="$test_root/compose-args"

mkdir -p "$WORK_DIR/$VOX_DIR" "$REPO_PATH"
git -C "$REPO_PATH" init -q -b main
git -C "$REPO_PATH" config user.name "vox test"
git -C "$REPO_PATH" config user.email "vox-test@example.invalid"
printf 'fixture\n' > "$REPO_PATH/fixture.txt"
git -C "$REPO_PATH" add fixture.txt
git -C "$REPO_PATH" commit -q -m "fixture"

printf '%s\n' \
  '#!/usr/bin/env bash' \
  "printf '# comments and blank lines are ignored\\n\\n'" \
  "printf 'BUILD_GIT_SHA=%s\\n' \"\$VOX_GIT_SHA_SHORT\"" \
  "printf 'BUILD_GIT_COMMIT_COUNT=%s\\n' \"\$VOX_GIT_COMMIT_COUNT\"" \
  "printf 'VALUE_WITH_EQUALS=a=b\\n'" \
  > "$WORK_DIR/$VOX_DIR/build-args"
chmod +x "$WORK_DIR/$VOX_DIR/build-args"

fake_compose() {
  printf '%s\n' "$@" > "$capture_file"
}

cd "$WORK_DIR"
build_log=$(compose_build)
short_sha=$(git -C "$REPO_PATH" rev-parse --short HEAD)

grep -Fx -- "--build-arg" "$capture_file" >/dev/null
grep -Fx -- "BUILD_GIT_SHA=$short_sha" "$capture_file" >/dev/null
grep -Fx -- "BUILD_GIT_COMMIT_COUNT=1" "$capture_file" >/dev/null
grep -Fx -- "VALUE_WITH_EQUALS=a=b" "$capture_file" >/dev/null
[[ "$build_log" == *"BUILD_GIT_SHA BUILD_GIT_COMMIT_COUNT VALUE_WITH_EQUALS"* ]]
[[ "$build_log" != *"a=b"* ]]

printf 'not-a-pair\n' > "$WORK_DIR/$VOX_DIR/build-args"
if compose_build >/dev/null 2>&1; then
  echo "expected invalid hook output to fail" >&2
  exit 1
else
  rc=$?
  [[ "$rc" -eq 78 ]]
fi

echo "build-args hook tests passed"
