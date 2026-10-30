#!/usr/bin/env bash
# 共用設定與函式：所有腳本都會 source 這個檔案
# shellcheck disable=SC2034

set -euo pipefail

# ---------- 可覆寫的環境變數 ----------
export AWS_REGION="${AWS_REGION:-eu-central-1}"
export AWS_DEFAULT_REGION="$AWS_REGION"
PREFIX="${PREFIX:-bank-demo}"                 # 所有示範資源的名稱前綴
STATE_DIR="${STATE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/.state}"
STATE_FILE="$STATE_DIR/${PREFIX}-${AWS_REGION}.env"
ASSUME_YES="${ASSUME_YES:-false}"            # true = 不互動確認（CI 用）
TAG_KEY="Project"
TAG_VALUE="$PREFIX"

mkdir -p "$STATE_DIR"
touch "$STATE_FILE"

# ---------- 輸出 ----------
c_reset=$'\033[0m'; c_red=$'\033[31m'; c_green=$'\033[32m'; c_yellow=$'\033[33m'; c_blue=$'\033[34m'
info()  { printf '%s[INFO]%s %s\n' "$c_blue" "$c_reset" "$*"; }
ok()    { printf '%s[ OK ]%s %s\n' "$c_green" "$c_reset" "$*"; }
warn()  { printf '%s[WARN]%s %s\n' "$c_yellow" "$c_reset" "$*"; }
fail()  { printf '%s[FAIL]%s %s\n' "$c_red" "$c_reset" "$*"; }
die()   { fail "$*"; exit 1; }
step()  { printf '\n%s==> %s%s\n' "$c_blue" "$*" "$c_reset"; }

# ---------- 前置檢查 ----------
require() {
  local cmd
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || die "找不到指令：$cmd，請先安裝"
  done
}

ensure_aws() {
  require aws jq
  local ident
  ident="$(aws sts get-caller-identity --output json 2>/dev/null)" || die "無法取得 AWS 身分，請先設定憑證（aws configure / aws sso login）"
  ACCOUNT_ID="$(jq -r .Account <<<"$ident")"
  CALLER_ARN="$(jq -r .Arn <<<"$ident")"
  info "帳號：${ACCOUNT_ID:0:4}********　區域：$AWS_REGION　身分：$(sed -E 's/[0-9]{12}/************/' <<<"$CALLER_ARN")"
  if [[ "$CALLER_ARN" == *":root" ]]; then
    warn "目前以 Root 身分執行。建議改用 IAM Identity Center 或管理角色（GuardDuty 會產生 RootCredentialUsage 告警）。"
  fi
}

confirm() {
  local msg="$1"
  [[ "$ASSUME_YES" == "true" ]] && return 0
  read -r -p "$msg [y/N] " ans
  [[ "$ans" =~ ^[Yy]$ ]]
}

# ---------- 狀態檔：記錄建立的資源，供 99-cleanup.sh 使用 ----------
state_set() {
  local key="$1" val="$2"
  grep -v "^${key}=" "$STATE_FILE" > "$STATE_FILE.tmp" || true
  echo "${key}=${val}" >> "$STATE_FILE.tmp"
  mv "$STATE_FILE.tmp" "$STATE_FILE"
}
state_get() {
  local key="$1"
  grep "^${key}=" "$STATE_FILE" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

tags_json() { printf '[{"Key":"%s","Value":"%s"}]' "$TAG_KEY" "$TAG_VALUE"; }
