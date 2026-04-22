#!/usr/bin/env bash
set -euo pipefail

SELF_NAME="${0##*/}"
CURRENT_DIR="$(pwd -P)"

log() {
  printf '[omx-bridge] %s\n' "$*" >&2
}

print_stdout_lines() {
  local line
  for line in "$@"; do
    printf '%s\n' "$line"
  done
}

print_stderr_lines() {
  local line
  for line in "$@"; do
    printf '%s\n' "$line" >&2
  done
}

die() {
  log "ERROR: $*"
  exit 1
}

resolve_path() {
  case "$1" in
    /*) printf '%s\n' "$1" ;;
    *) printf '%s\n' "${PROJECT_ROOT:-$CURRENT_DIR}/$1" ;;
  esac
}

require_program() {
  local program="$1"
  if [[ "$program" == */* ]]; then
    [[ -x "$program" ]] || die "Required executable not found: $program"
    return 0
  fi

  command -v "$program" >/dev/null 2>&1 || die "Required executable not found in PATH: $program"
}

is_commit_like_ref() {
  [[ "$1" =~ ^[0-9a-fA-F]{7,40}$ ]]
}

current_git_head() {
  "$GIT_BIN" -C "$OMX_SOURCE_DIR" rev-parse HEAD 2>/dev/null || true
}

sync_omx_git_checkout() {
  require_program "$GIT_BIN"

  if [[ ! -d "$OMX_SOURCE_DIR/.git" ]]; then
    rm -rf "$OMX_SOURCE_DIR"
    log "Cloning upstream OMX from $OMX_REPO_URL"
    "$GIT_BIN" clone --depth 1 "$OMX_REPO_URL" "$OMX_SOURCE_DIR"
  fi

  log "Checking out upstream OMX ref $OMX_REPO_REF"
  "$GIT_BIN" -C "$OMX_SOURCE_DIR" fetch --depth 1 origin "$OMX_REPO_REF"
  "$GIT_BIN" -C "$OMX_SOURCE_DIR" checkout --detach FETCH_HEAD
}

normalize_lower_trimmed() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]'
}

validate_openai_api_key() {
  local raw_value="${OPENAI_API_KEY:-}"
  local normalized

  [[ -n "$raw_value" ]] || die "OPENAI_API_KEY is required for codex-login-api-key"

  normalized="$(normalize_lower_trimmed "$raw_value")"
  case "$normalized" in
    ""|none|null|undefined)
      die "OPENAI_API_KEY must be a real API key. If your main Codex login uses a ChatGPT account session, use '$SELF_NAME codex-login-device' for the isolated project login."
      ;;
  esac
}

timestamp() {
  date '+%Y%m%d-%H%M%S'
}

record_invocation() {
  local label="$1"
  shift

  mkdir -p "$RUNS_DIR"
  local record_path="$RUNS_DIR/$(timestamp)-${label}.log"
  {
    printf 'label=%s\n' "$label"
    printf 'project_root=%s\n' "$PROJECT_ROOT"
    printf 'omx_source_dir=%s\n' "$OMX_SOURCE_DIR"
    printf 'codex_home=%s\n' "$PROJECT_CODEX_HOME"
    printf 'cwd=%s\n' "$(pwd)"
    printf 'argv='
    printf '%q ' "$@"
    printf '\n'
  } >"$record_path"
}

ensure_project_dirs() {
  mkdir -p "$PROJECT_ROOT" "$PROJECT_CODEX_HOME" "$RUNTIME_ROOT" "$RUNS_DIR"
}

resolve_omx_entrypoint() {
  local candidate

  if [[ -n "${OMX_ENTRYPOINT:-}" ]]; then
    candidate="$(resolve_path "$OMX_ENTRYPOINT")"
    [[ -f "$candidate" ]] || die "OMX_ENTRYPOINT does not exist: $candidate"
    printf '%s\n' "$candidate"
    return 0
  fi

  for candidate in \
    "$OMX_SOURCE_DIR/dist/cli/omx.js" \
    "$OMX_SOURCE_DIR/bin/omx.js"
  do
    if [[ -f "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  die "Could not find a local OMX entrypoint. Run '$SELF_NAME bootstrap' first."
}

local_codex_login_status() {
  ensure_project_dirs
  CODEX_HOME="$PROJECT_CODEX_HOME" "$CODEX_BIN" login status
}

ensure_local_codex_auth() {
  ensure_project_dirs
  if CODEX_HOME="$PROJECT_CODEX_HOME" "$CODEX_BIN" login status >/dev/null 2>&1; then
    return 0
  fi

  print_stderr_lines \
    "[omx-bridge] No project-local Codex login found in:" \
    "[omx-bridge]   $PROJECT_CODEX_HOME" \
    "[omx-bridge] To continue, use one of:" \
    "[omx-bridge]   $SELF_NAME codex-login-device" \
    "[omx-bridge]   OPENAI_API_KEY=... $SELF_NAME codex-login-api-key"
  exit 1
}

subcommand_requires_auth() {
  case "${1:-}" in
    ""|exec|question|team|swarm)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

bootstrap_omx() {
  local update_existing=0
  if [[ "${1:-}" == "--update" ]]; then
    update_existing=1
    shift
  fi
  [[ $# -eq 0 ]] || die "bootstrap accepts at most one flag: --update"

  require_program "$NODE_BIN"
  require_program "$NPM_BIN"

  ensure_project_dirs
  mkdir -p "$(dirname "$OMX_SOURCE_DIR")"
  if [[ "$update_existing" -eq 1 ]]; then
    record_invocation "bootstrap" "$SELF_NAME" bootstrap --update
  else
    record_invocation "bootstrap" "$SELF_NAME" bootstrap
  fi

  if [[ -d "$OMX_SOURCE_DIR/.git" ]]; then
    local current_head=""
    current_head="$(current_git_head)"

    if [[ "$update_existing" -eq 1 ]]; then
      log "Updating existing OMX checkout in $OMX_SOURCE_DIR"
      sync_omx_git_checkout
    elif is_commit_like_ref "$OMX_REPO_REF" && [[ "$current_head" == "$OMX_REPO_REF" ]]; then
      log "Reusing existing OMX checkout at pinned ref $OMX_REPO_REF"
    else
      log "Aligning existing OMX checkout to upstream ref $OMX_REPO_REF"
      sync_omx_git_checkout
    fi
  elif [[ -f "$OMX_SOURCE_DIR/package.json" ]]; then
    log "Reusing existing local OMX source directory: $OMX_SOURCE_DIR"
  else
    sync_omx_git_checkout
  fi

  [[ -f "$OMX_SOURCE_DIR/package.json" ]] || die "OMX source directory is missing package.json: $OMX_SOURCE_DIR"

  if [[ -f "$OMX_SOURCE_DIR/package-lock.json" ]]; then
    log "Installing upstream OMX dependencies with npm ci --ignore-scripts"
    (
      cd "$OMX_SOURCE_DIR"
      "$NPM_BIN" ci --ignore-scripts
    )
  else
    log "Installing upstream OMX dependencies with npm install --ignore-scripts"
    (
      cd "$OMX_SOURCE_DIR"
      "$NPM_BIN" install --ignore-scripts
    )
  fi

  log "Building upstream OMX"
  (
    cd "$OMX_SOURCE_DIR"
    "$NPM_BIN" run build
  )

  log "Bootstrap complete"
}

run_local_omx() {
  local entrypoint="$1"
  shift

  require_program "$NODE_BIN"
  record_invocation "omx" "$NODE_BIN" "$entrypoint" "$@"
  (
    cd "$PROJECT_ROOT"
    CODEX_HOME="$PROJECT_CODEX_HOME" "$NODE_BIN" "$entrypoint" "$@"
  )
}

print_status() {
  local entrypoint=""
  if entrypoint="$(resolve_omx_entrypoint 2>/dev/null)"; then
    :
  else
    entrypoint="(not built yet)"
  fi

  print_stdout_lines \
    "project_root=$PROJECT_ROOT" \
    "project_codex_home=$PROJECT_CODEX_HOME" \
    "project_omx_dir=$PROJECT_OMX_DIR" \
    "bridge_runtime_root=$RUNTIME_ROOT" \
    "runs_dir=$RUNS_DIR" \
    "omx_source_dir=$OMX_SOURCE_DIR" \
    "omx_entrypoint=$entrypoint" \
    "omx_repo_url=$OMX_REPO_URL" \
    "omx_repo_ref=$OMX_REPO_REF"

  if local_codex_login_status; then
    :
  else
    log "Project-local Codex login is not configured yet"
  fi
}

print_help() {
  print_stdout_lines \
    "$SELF_NAME - Project-local bridge between Codex App sessions and upstream oh-my-codex" \
    "" \
    "Usage:" \
    "  $SELF_NAME bootstrap [--update]" \
    "  $SELF_NAME setup [omx-setup-args...]" \
    "  $SELF_NAME doctor [omx-doctor-args...]" \
    "  $SELF_NAME launch [omx-launch-args...]" \
    "  $SELF_NAME launch-dangerous [omx-launch-args...]" \
    "  $SELF_NAME exec [omx-exec-args...]" \
    "  $SELF_NAME question [omx-question-args...]" \
    "  $SELF_NAME omx [upstream-omx-args...]" \
    "  $SELF_NAME status" \
    "  $SELF_NAME codex-login-status" \
    "  $SELF_NAME codex-login-device" \
    "  $SELF_NAME codex-login-api-key" \
    "" \
    "Environment:" \
    "  OMX_PROJECT_ROOT  Target project root (default: current working directory)" \
    "  OMX_SOURCE_DIR    Local OMX checkout (default: ./.omx-codex-app-bridge/vendor/oh-my-codex)" \
    "  OMX_REPO_URL      Upstream OMX repo URL" \
    "  OMX_REPO_REF      Upstream OMX commit, tag, or branch" \
    "  OMX_ENTRYPOINT    Explicit OMX entrypoint override" \
    "  CODEX_BIN         Codex CLI binary override" \
    "  NODE_BIN          Node.js binary override" \
    "  NPM_BIN           npm binary override" \
    "  GIT_BIN           git binary override" \
    "  OPENAI_API_KEY    Used only by codex-login-api-key"
}

warn_dangerous_launch() {
  print_stderr_lines \
    "[omx-bridge] WARNING: launch-dangerous uses upstream OMX with --madmax --high." \
    "[omx-bridge] This may bypass Codex approvals and sandboxing inside the launched OMX session." \
    "[omx-bridge] Keep using launch unless you explicitly want the dangerous upstream path."
}

PROJECT_ROOT="$(resolve_path "${OMX_PROJECT_ROOT:-$PWD}")"
RUNTIME_ROOT="$(resolve_path "${OMX_BRIDGE_RUNTIME_DIR:-$PROJECT_ROOT/.omx-codex-app-bridge}")"
RUNS_DIR="$RUNTIME_ROOT/runs"
OMX_SOURCE_DIR="$(resolve_path "${OMX_SOURCE_DIR:-$RUNTIME_ROOT/vendor/oh-my-codex}")"
PROJECT_CODEX_HOME="$PROJECT_ROOT/.codex"
PROJECT_OMX_DIR="$PROJECT_ROOT/.omx"
OMX_REPO_URL="${OMX_REPO_URL:-https://github.com/Yeachan-Heo/oh-my-codex.git}"
OMX_REPO_REF="${OMX_REPO_REF:-d56148c2020454acb37082d251f9a6ee9dba9f82}"
CODEX_BIN="${CODEX_BIN:-codex}"
NODE_BIN="${NODE_BIN:-node}"
NPM_BIN="${NPM_BIN:-npm}"
GIT_BIN="${GIT_BIN:-git}"

COMMAND="${1:-help}"
if [[ $# -gt 0 ]]; then
  shift
fi

case "$COMMAND" in
  help|-h|--help)
    print_help
    ;;
  bootstrap)
    bootstrap_omx "$@"
    ;;
  setup)
    entrypoint="$(resolve_omx_entrypoint)"
    run_local_omx "$entrypoint" setup --scope project "$@"
    ;;
  doctor)
    entrypoint="$(resolve_omx_entrypoint)"
    run_local_omx "$entrypoint" doctor "$@"
    ;;
  launch)
    entrypoint="$(resolve_omx_entrypoint)"
    ensure_local_codex_auth
    if [[ $# -eq 0 ]]; then
      run_local_omx "$entrypoint" --high
    else
      run_local_omx "$entrypoint" "$@"
    fi
    ;;
  launch-dangerous)
    entrypoint="$(resolve_omx_entrypoint)"
    ensure_local_codex_auth
    warn_dangerous_launch
    if [[ $# -eq 0 ]]; then
      run_local_omx "$entrypoint" --madmax --high
    else
      run_local_omx "$entrypoint" "$@"
    fi
    ;;
  exec)
    entrypoint="$(resolve_omx_entrypoint)"
    ensure_local_codex_auth
    run_local_omx "$entrypoint" exec "$@"
    ;;
  question)
    entrypoint="$(resolve_omx_entrypoint)"
    ensure_local_codex_auth
    run_local_omx "$entrypoint" question "$@"
    ;;
  omx)
    entrypoint="$(resolve_omx_entrypoint)"
    if subcommand_requires_auth "${1:-}"; then
      ensure_local_codex_auth
    fi
    run_local_omx "$entrypoint" "$@"
    ;;
  status)
    print_status
    ;;
  codex-login-status)
    record_invocation "codex-login-status" "$CODEX_BIN" login status
    local_codex_login_status
    ;;
  codex-login-device)
    require_program "$CODEX_BIN"
    ensure_project_dirs
    record_invocation "codex-login-device" "$CODEX_BIN" login --device-auth
    CODEX_HOME="$PROJECT_CODEX_HOME" "$CODEX_BIN" login --device-auth
    ;;
  codex-login-api-key)
    require_program "$CODEX_BIN"
    ensure_project_dirs
    validate_openai_api_key
    record_invocation "codex-login-api-key" "$CODEX_BIN" login --with-api-key
    printf '%s' "$OPENAI_API_KEY" | CODEX_HOME="$PROJECT_CODEX_HOME" "$CODEX_BIN" login --with-api-key
    ;;
  *)
    die "Unknown command: $COMMAND. Run '$SELF_NAME --help' for usage."
    ;;
esac
