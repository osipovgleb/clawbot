#!/usr/bin/env bash
set -euo pipefail

APP_ROOT="${APP_ROOT:-/opt/openclaw}"
REPO_DIR="${REPO_DIR:-$APP_ROOT/repo}"
RELEASES_DIR="${RELEASES_DIR:-$APP_ROOT/releases}"
CURRENT_LINK="${CURRENT_LINK:-$APP_ROOT/current}"
SERVICE_NAME="${SERVICE_NAME:-openclaw.service}"
SERVICE_USER="${SERVICE_USER:-openclaw}"
KEEP_RELEASES="${KEEP_RELEASES:-8}"
HEALTH_URL_PRIMARY="${HEALTH_URL_PRIMARY:-http://127.0.0.1:18789/healthz}"
HEALTH_URL_FALLBACK="${HEALTH_URL_FALLBACK:-http://127.0.0.1:18789/}"
HEALTH_RETRIES="${HEALTH_RETRIES:-80}"
HEALTH_DELAY_SECONDS="${HEALTH_DELAY_SECONDS:-3}"

log() {
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

health_check() {
  local i
  for ((i = 1; i <= HEALTH_RETRIES; i++)); do
    if curl -fsS "$HEALTH_URL_PRIMARY" >/dev/null 2>&1; then
      return 0
    fi
    if curl -fsS "$HEALTH_URL_FALLBACK" >/dev/null 2>&1; then
      return 0
    fi
    sleep "$HEALTH_DELAY_SECONDS"
  done
  return 1
}

restart_service() {
  systemctl restart "$SERVICE_NAME"
}

rollback_to_path() {
  local target_path="$1"
  log "Rolling back to $target_path"
  ln -sfn "$target_path" "$CURRENT_LINK"
  restart_service
  health_check
}

prune_releases() {
  mapfile -t release_paths < <(ls -1dt "$RELEASES_DIR"/* 2>/dev/null || true)
  if ((${#release_paths[@]} <= KEEP_RELEASES)); then
    return 0
  fi
  for old_release in "${release_paths[@]:$KEEP_RELEASES}"; do
    log "Pruning old release: $old_release"
    rm -rf "$old_release"
  done
}

deploy_sha() {
  local sha="$1"
  local previous_target=""
  local release_id
  local release_dir

  require_cmd git
  require_cmd rsync
  require_cmd curl
  require_cmd systemctl
  require_cmd corepack

  mkdir -p "$RELEASES_DIR"

  if [[ ! -d "$REPO_DIR/.git" ]]; then
    echo "Repository not found at $REPO_DIR. Bootstrap it first." >&2
    exit 1
  fi

  if [[ -L "$CURRENT_LINK" || -e "$CURRENT_LINK" ]]; then
    previous_target="$(readlink -f "$CURRENT_LINK" || true)"
  fi

  log "Fetching repository updates"
  git -C "$REPO_DIR" fetch --prune origin

  log "Checking out commit $sha"
  git -C "$REPO_DIR" checkout --detach "$sha"

  release_id="$(date -u +%Y%m%d%H%M%S)-${sha:0:7}"
  release_dir="$RELEASES_DIR/$release_id"
  mkdir -p "$release_dir"

  log "Preparing release dir $release_dir"
  rsync -a --delete \
    --exclude ".git" \
    --exclude "node_modules" \
    --exclude "releases" \
    --exclude "current" \
    "$REPO_DIR/" "$release_dir/"

  pushd "$release_dir" >/dev/null
  log "Installing dependencies"
  corepack pnpm install --frozen-lockfile
  log "Building release"
  corepack pnpm run build
  popd >/dev/null

  chown -R "$SERVICE_USER:$SERVICE_USER" "$release_dir"

  log "Switching current symlink to $release_id"
  ln -sfn "$release_dir" "$CURRENT_LINK"

  log "Restarting service"
  if ! restart_service; then
    if [[ -n "$previous_target" ]]; then
      rollback_to_path "$previous_target"
    fi
    exit 1
  fi

  if ! health_check; then
    log "Health check failed for $release_id"
    if [[ -n "$previous_target" ]]; then
      rollback_to_path "$previous_target"
      log "Rollback succeeded: $previous_target"
    fi
    exit 1
  fi

  log "Deploy succeeded: $release_id"
  prune_releases
}

rollback_release() {
  local release_id="$1"
  local target="$RELEASES_DIR/$release_id"
  if [[ ! -d "$target" ]]; then
    echo "Release not found: $target" >&2
    exit 1
  fi
  rollback_to_path "$target"
  log "Rollback finished: $release_id"
}

list_releases() {
  ls -1dt "$RELEASES_DIR"/* 2>/dev/null || true
}

usage() {
  cat <<EOF
Usage:
  deploy.sh <commit_sha>
  deploy.sh rollback <release_id>
  deploy.sh list
EOF
}

main() {
  if [[ $# -lt 1 ]]; then
    usage
    exit 1
  fi

  case "$1" in
    rollback)
      [[ $# -eq 2 ]] || {
        usage
        exit 1
      }
      rollback_release "$2"
      ;;
    list)
      list_releases
      ;;
    *)
      [[ $# -eq 1 ]] || {
        usage
        exit 1
      }
      deploy_sha "$1"
      ;;
  esac
}

main "$@"
