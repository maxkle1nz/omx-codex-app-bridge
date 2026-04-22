#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
BRIDGE_SCRIPT="$REPO_ROOT/skills/omx-codex-app-bridge/scripts/omx-bridge.sh"
TMP_ROOT="$REPO_ROOT/.tmp/test-omx-bridge"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  [[ "$haystack" == *"$needle"* ]] || fail "expected output to contain: $needle"
}

assert_file_contains() {
  local path="$1"
  local needle="$2"
  [[ -f "$path" ]] || fail "missing file: $path"
  grep -Fq -- "$needle" "$path" || fail "expected $path to contain: $needle"
}

create_fake_codex() {
  local path="$1"
  cat >"$path" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

mkdir -p "${FAKE_LOG_DIR:?}"
printf 'CODEX_HOME=%s ARGS=' "${CODEX_HOME:-}" >>"${FAKE_LOG_DIR}/codex.log"
printf '%q ' "$@" >>"${FAKE_LOG_DIR}/codex.log"
printf '\n' >>"${FAKE_LOG_DIR}/codex.log"

auth_path="${CODEX_HOME:-}/auth.json"

case "${1:-}" in
  login)
    case "${2:-}" in
      status)
        if [[ -f "$auth_path" ]]; then
          echo "Logged in (fake)"
          exit 0
        fi
        echo "Not logged in"
        exit 1
        ;;
      --device-auth)
        mkdir -p "$(dirname "$auth_path")"
        printf '{"mode":"device"}\n' >"$auth_path"
        echo "Device auth complete (fake)"
        ;;
      --with-api-key)
        key="$(cat)"
        [[ -n "$key" ]] || {
          echo "Missing API key" >&2
          exit 1
        }
        mkdir -p "$(dirname "$auth_path")"
        printf '{"mode":"api-key"}\n' >"$auth_path"
        echo "API key auth complete (fake)"
        ;;
      *)
        echo "Unsupported login invocation" >&2
        exit 2
        ;;
    esac
    ;;
  *)
    echo "Unsupported codex invocation" >&2
    exit 2
    ;;
esac
EOF
  chmod +x "$path"
}

create_fake_omx_source() {
  local dir="$1"

  mkdir -p "$dir/dist/cli"
  cat >"$dir/package.json" <<'EOF'
{
  "name": "fake-omx",
  "version": "0.0.0",
  "private": true,
  "scripts": {
    "build": "node -e \"process.exit(0)\""
  }
}
EOF

  cat >"$dir/dist/cli/omx.js" <<'EOF'
#!/usr/bin/env node
const fs = require("fs");
const path = require("path");

const logDir = process.env.FAKE_LOG_DIR;
if (!logDir) {
  throw new Error("FAKE_LOG_DIR is required");
}

fs.mkdirSync(logDir, { recursive: true });
fs.appendFileSync(
  path.join(logDir, "omx.log"),
  JSON.stringify({
    cwd: process.cwd(),
    argv: process.argv.slice(2),
    codexHome: process.env.CODEX_HOME || null
  }) + "\n"
);
EOF
  chmod +x "$dir/dist/cli/omx.js"
}

create_fake_npm() {
  local path="$1"
  cat >"$path" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'ARGS=' >>"${FAKE_LOG_DIR}/npm.log"
printf '%q ' "$@" >>"${FAKE_LOG_DIR}/npm.log"
printf '\n' >>"${FAKE_LOG_DIR}/npm.log"
EOF
  chmod +x "$path"
}

create_git_omx_source_repo() {
  local dir="$1"

  create_fake_omx_source "$dir"
  git -C "$dir" init -q -b main
  git -C "$dir" add .
  git -C "$dir" -c user.name="Test User" -c user.email="test@example.com" commit -q -m "Initial fake OMX source"
}

reset_tmp() {
  rm -rf "$TMP_ROOT"
  mkdir -p "$TMP_ROOT"
}

run_bridge() {
  local project_root="$1"
  shift
  OMX_PROJECT_ROOT="$project_root" \
  OMX_SOURCE_DIR="$project_root/fake-upstream-omx" \
  CODEX_BIN="$project_root/fake-codex.sh" \
  NPM_BIN="$project_root/fake-npm.sh" \
  FAKE_LOG_DIR="$project_root/logs" \
  "$BRIDGE_SCRIPT" "$@"
}

test_bootstrap_uses_ignore_scripts() {
  reset_tmp
  local project_root="$TMP_ROOT/bootstrap"
  mkdir -p "$project_root/logs"
  create_fake_codex "$project_root/fake-codex.sh"
  create_fake_omx_source "$project_root/fake-upstream-omx"
  create_fake_npm "$project_root/fake-npm.sh"

  run_bridge "$project_root" bootstrap

  assert_file_contains "$project_root/logs/npm.log" "install --ignore-scripts"
  assert_file_contains "$project_root/logs/npm.log" "run build"
}

test_bootstrap_clones_pinned_commit_ref() {
  reset_tmp
  local project_root="$TMP_ROOT/bootstrap-pinned-ref"
  local source_repo="$TMP_ROOT/source-omx-repo"
  local pinned_ref=""
  mkdir -p "$project_root/logs"
  create_fake_codex "$project_root/fake-codex.sh"
  create_fake_npm "$project_root/fake-npm.sh"
  create_git_omx_source_repo "$source_repo"
  pinned_ref="$(git -C "$source_repo" rev-parse HEAD)"

  OMX_PROJECT_ROOT="$project_root" \
  OMX_REPO_URL="$source_repo" \
  OMX_REPO_REF="$pinned_ref" \
  CODEX_BIN="$project_root/fake-codex.sh" \
  NPM_BIN="$project_root/fake-npm.sh" \
  FAKE_LOG_DIR="$project_root/logs" \
  "$BRIDGE_SCRIPT" bootstrap

  [[ "$(git -C "$project_root/.omx-codex-app-bridge/vendor/oh-my-codex" rev-parse HEAD)" == "$pinned_ref" ]] \
    || fail "bootstrap did not pin the upstream checkout to the requested commit"
  assert_file_contains "$project_root/logs/npm.log" "install --ignore-scripts"
}

test_setup_forces_project_scope() {
  reset_tmp
  local project_root="$TMP_ROOT/setup"
  mkdir -p "$project_root/logs"
  create_fake_codex "$project_root/fake-codex.sh"
  create_fake_omx_source "$project_root/fake-upstream-omx"
  create_fake_npm "$project_root/fake-npm.sh"

  run_bridge "$project_root" setup --dry-run

  assert_file_contains "$project_root/logs/omx.log" "\"argv\":[\"setup\",\"--scope\",\"project\",\"--dry-run\"]"
  assert_file_contains "$project_root/logs/omx.log" "\"codexHome\":\"$project_root/.codex\""
}

test_launch_requires_local_auth() {
  reset_tmp
  local project_root="$TMP_ROOT/launch-auth"
  local stdout_path="$project_root/launch.stdout"
  local stderr_path="$project_root/launch.stderr"
  mkdir -p "$project_root/logs"
  create_fake_codex "$project_root/fake-codex.sh"
  create_fake_omx_source "$project_root/fake-upstream-omx"
  create_fake_npm "$project_root/fake-npm.sh"

  if run_bridge "$project_root" launch >"$stdout_path" 2>"$stderr_path"; then
    fail "launch should fail without local auth"
  fi

  assert_file_contains "$stderr_path" "No project-local Codex login found"
}

test_login_api_key_and_exec_use_project_codex_home() {
  reset_tmp
  local project_root="$TMP_ROOT/login-and-exec"
  mkdir -p "$project_root/logs"
  create_fake_codex "$project_root/fake-codex.sh"
  create_fake_omx_source "$project_root/fake-upstream-omx"
  create_fake_npm "$project_root/fake-npm.sh"

  OPENAI_API_KEY="test-key" run_bridge "$project_root" codex-login-api-key
  [[ -f "$project_root/.codex/auth.json" ]] || fail "expected local auth to be written"

  run_bridge "$project_root" exec --skip-git-repo-check -C . "Reply with exactly OMX-EXEC-OK"

  assert_file_contains "$project_root/logs/codex.log" "CODEX_HOME=$project_root/.codex"
  assert_file_contains "$project_root/logs/omx.log" "\"argv\":[\"exec\",\"--skip-git-repo-check\",\"-C\",\".\",\"Reply with exactly OMX-EXEC-OK\"]"
}

test_login_api_key_rejects_placeholder_values() {
  reset_tmp
  local project_root="$TMP_ROOT/login-api-key-invalid"
  local stderr_path="$project_root/login.stderr"
  mkdir -p "$project_root/logs"
  create_fake_codex "$project_root/fake-codex.sh"
  create_fake_omx_source "$project_root/fake-upstream-omx"
  create_fake_npm "$project_root/fake-npm.sh"

  if OPENAI_API_KEY="None" run_bridge "$project_root" codex-login-api-key >"$project_root/login.stdout" 2>"$stderr_path"; then
    fail "codex-login-api-key should reject placeholder values like None"
  fi

  assert_file_contains "$stderr_path" "OPENAI_API_KEY must be a real API key"
  [[ ! -f "$project_root/.codex/auth.json" ]] || fail "placeholder API key should not create local auth"
  [[ ! -f "$project_root/logs/codex.log" ]] || fail "wrapper should reject placeholder API key before invoking codex"
}

test_launch_defaults_to_high_only() {
  reset_tmp
  local project_root="$TMP_ROOT/launch-defaults"
  mkdir -p "$project_root/logs"
  create_fake_codex "$project_root/fake-codex.sh"
  create_fake_omx_source "$project_root/fake-upstream-omx"
  create_fake_npm "$project_root/fake-npm.sh"

  OPENAI_API_KEY="test-key" run_bridge "$project_root" codex-login-api-key
  run_bridge "$project_root" launch

  assert_file_contains "$project_root/logs/omx.log" "\"argv\":[\"--high\"]"
}

test_launch_dangerous_uses_madmax_high() {
  reset_tmp
  local project_root="$TMP_ROOT/launch-dangerous"
  mkdir -p "$project_root/logs"
  create_fake_codex "$project_root/fake-codex.sh"
  create_fake_omx_source "$project_root/fake-upstream-omx"
  create_fake_npm "$project_root/fake-npm.sh"

  OPENAI_API_KEY="test-key" run_bridge "$project_root" codex-login-api-key
  run_bridge "$project_root" launch-dangerous >"$project_root/dangerous.stdout" 2>"$project_root/dangerous.stderr"

  assert_file_contains "$project_root/logs/omx.log" "\"argv\":[\"--madmax\",\"--high\"]"
  assert_file_contains "$project_root/dangerous.stderr" "WARNING: launch-dangerous uses upstream OMX"
}

test_status_reports_paths() {
  reset_tmp
  local project_root="$TMP_ROOT/status"
  mkdir -p "$project_root/logs"
  create_fake_codex "$project_root/fake-codex.sh"
  create_fake_omx_source "$project_root/fake-upstream-omx"
  create_fake_npm "$project_root/fake-npm.sh"

  output="$(run_bridge "$project_root" status 2>&1 || true)"

  assert_contains "$output" "project_root=$project_root"
  assert_contains "$output" "project_codex_home=$project_root/.codex"
  assert_contains "$output" "bridge_runtime_root=$project_root/.omx-codex-app-bridge"
}

test_bootstrap_uses_ignore_scripts
test_bootstrap_clones_pinned_commit_ref
test_setup_forces_project_scope
test_launch_requires_local_auth
test_login_api_key_and_exec_use_project_codex_home
test_login_api_key_rejects_placeholder_values
test_launch_defaults_to_high_only
test_launch_dangerous_uses_madmax_high
test_status_reports_paths

printf 'PASS: omx-bridge wrapper tests\n'
