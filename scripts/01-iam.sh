#!/usr/bin/env bash
# 模組 B｜身分與權限
#   101：密碼政策、需 MFA 才能擔任的稽核唯讀角色
#   102：IAM Access Analyzer（外部存取，免費）
#
# 用法：./scripts/01-iam.sh [password-policy|auditor-role|access-analyzer|all]
# 每個會變更帳號設定的動作執行前都會詢問確認（ASSUME_YES=true 可略過）。
source "$(dirname "$0")/lib/common.sh"
ensure_aws
POL_DIR="$(dirname "$0")/policies"
ROLE_NAME="${PREFIX}-InternalAuditor-ReadOnly"
ANALYZER_NAME="${PREFIX}-external-access"

password_policy() {
  step "Step 2–3：設定密碼政策（14 碼、四類字元、90 天、記住 24 組）"
  if aws iam get-account-password-policy --output json >"$STATE_DIR/password-policy.backup.json" 2>/dev/null; then
    info "已備份現有密碼政策到 $STATE_DIR/password-policy.backup.json"
  else
    rm -f "$STATE_DIR/password-policy.backup.json"
    info "目前使用 AWS 預設密碼政策"
  fi
  confirm "此設定會影響帳號內所有 IAM 使用者，確定要更新密碼政策？" || { warn "略過"; return; }
  aws iam update-account-password-policy \
    --minimum-password-length 14 \
    --require-uppercase-characters --require-lowercase-characters \
    --require-numbers --require-symbols \
    --max-password-age 90 --password-reuse-prevention 24 \
    --allow-users-to-change-password
  state_set PASSWORD_POLICY_CHANGED true
  ok "密碼政策已更新"
}

auditor_role() {
  step "Step 4–9：建立需要 MFA 的稽核唯讀角色 $ROLE_NAME"
  if aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
    ok "角色已存在，略過建立"; return
  fi
  local trust
  trust="$(sed "s/ACCOUNT_ID/${ACCOUNT_ID}/g" "$POL_DIR/trust-mfa-same-account.json")"
  confirm "建立 IAM 角色 $ROLE_NAME 並附加 SecurityAudit？" || { warn "略過"; return; }
  aws iam create-role --role-name "$ROLE_NAME" \
    --assume-role-policy-document "$trust" \
    --description "Internal audit read-only role, MFA required (${PREFIX})" \
    --max-session-duration 3600 \
    --tags "Key=$TAG_KEY,Value=$TAG_VALUE" "Key=Owner,Value=InternalAudit" >/dev/null
  aws iam attach-role-policy --role-name "$ROLE_NAME" \
    --policy-arn arn:aws:iam::aws:policy/SecurityAudit
  state_set IAM_ROLE "$ROLE_NAME"
  ok "角色已建立。切換角色網址：https://signin.aws.amazon.com/switchrole?roleName=${ROLE_NAME}&account=<帳號 ID>"
}

access_analyzer() {
  step "Step 13–14：建立 IAM Access Analyzer（外部存取，無額外費用）"
  if aws accessanalyzer get-analyzer --analyzer-name "$ANALYZER_NAME" >/dev/null 2>&1; then
    ok "分析器已存在"; return
  fi
  confirm "在 $AWS_REGION 建立外部存取分析器 $ANALYZER_NAME？" || { warn "略過"; return; }
  aws accessanalyzer create-analyzer --analyzer-name "$ANALYZER_NAME" --type ACCOUNT \
    --tags "$TAG_KEY=$TAG_VALUE" >/dev/null
  state_set ACCESS_ANALYZER "$ANALYZER_NAME"
  ok "分析器已建立；結果請到 IAM → 存取分析器 查看"
}

case "${1:-all}" in
  password-policy) password_policy ;;
  auditor-role)    auditor_role ;;
  access-analyzer) access_analyzer ;;
  all)             password_policy; auditor_role; access_analyzer ;;
  *) die "未知參數：$1" ;;
esac
