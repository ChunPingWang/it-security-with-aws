#!/usr/bin/env bash
# 模組 F｜清理：只刪除「本專案腳本建立並記錄在 .state/」的資源
# 刪除順序依相依性：WAF → Flow Logs → SG → VPC → Config → Trail → 日誌桶
#                 → Security Hub → GuardDuty → 資料桶 → KMS（排程 7 天）→ IAM → SCP / OU
#
# 用法：./scripts/99-cleanup.sh            （逐項確認）
#       ASSUME_YES=true ./scripts/99-cleanup.sh
# 不會處理：帳號層級 S3 封鎖公開存取（建議保留）、AWS Organizations 本身。
source "$(dirname "$0")/lib/common.sh"
ensure_aws

[[ -s "$STATE_FILE" ]] || { info "狀態檔 $STATE_FILE 為空，沒有需要清理的資源"; exit 0; }
info "依據狀態檔：$STATE_FILE"
sed 's/^/    /' "$STATE_FILE"
confirm "確定刪除以上資源？" || exit 0
ASSUME_YES=true   # 已整體確認，以下不再逐項詢問

run() { "$@" 2>/dev/null || warn "略過（可能已刪除）：$*"; }

empty_bucket() {
  local b="$1" batch
  info "清空儲存貯體（含所有版本）：$b"
  while :; do
    batch="$(aws s3api list-object-versions --bucket "$b" --max-items 500 --output json \
      | jq -c '{Objects: ([(.Versions // [])[], (.DeleteMarkers // [])[]] | map({Key, VersionId})), Quiet: true}')"
    [[ "$(jq '.Objects | length' <<<"$batch")" -eq 0 ]] && break
    aws s3api delete-objects --bucket "$b" --delete "$batch" >/dev/null
  done
}

# ---------- E. 網路 ----------
if id="$(state_get WAF_ID)" && [[ -n "$id" ]]; then
  step "刪除 WAF Web ACL"
  lock="$(aws wafv2 get-web-acl --scope REGIONAL --name "$(state_get WAF_NAME)" --id "$id" --query LockToken --output text)"
  run aws wafv2 delete-web-acl --scope REGIONAL --name "$(state_get WAF_NAME)" --id "$id" --lock-token "$lock"
fi
if id="$(state_get FLOWLOG_ID)" && [[ -n "$id" ]]; then
  step "刪除 VPC Flow Logs"
  run aws ec2 delete-flow-logs --flow-log-ids "$id"
fi
if lg="$(state_get FLOWLOG_GROUP)" && [[ -n "$lg" ]]; then run aws logs delete-log-group --log-group-name "$lg"; fi
if role="$(state_get FLOWLOG_ROLE)" && [[ -n "$role" ]]; then
  run aws iam delete-role-policy --role-name "$role" --policy-name flowlogs-to-cwl
  run aws iam delete-role --role-name "$role"
fi
if id="$(state_get SG_ID)" && [[ -n "$id" ]]; then
  step "刪除 Security Group $id"
  run aws ec2 delete-security-group --group-id "$id"
fi
if vpc="$(state_get VPC_ID)" && [[ -n "$vpc" ]]; then
  step "刪除 VPC $vpc 及其端點、子網路、路由表"
  for e in $(aws ec2 describe-vpc-endpoints --filters "Name=vpc-id,Values=$vpc" --query 'VpcEndpoints[].VpcEndpointId' --output text); do
    run aws ec2 delete-vpc-endpoints --vpc-endpoint-ids "$e"
  done
  for s in $(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$vpc" --query 'Subnets[].SubnetId' --output text); do
    run aws ec2 delete-subnet --subnet-id "$s"
  done
  for r in $(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$vpc" \
             --query 'RouteTables[?!(Associations[?Main])].RouteTableId' --output text); do
    run aws ec2 delete-route-table --route-table-id "$r"
  done
  sleep 5
  run aws ec2 delete-vpc --vpc-id "$vpc"
fi

# ---------- D. 稽核與偵測 ----------
if [[ "$(state_get CONFIG_RULES)" == "true" ]]; then
  step "刪除 AWS Config 規則"
  for r in $(aws configservice describe-config-rules --query "ConfigRules[?starts_with(ConfigRuleName,'${PREFIX}-')].ConfigRuleName" --output text); do
    run aws configservice delete-config-rule --config-rule-name "$r"
  done
fi
if [[ -n "$(state_get CONFIG_RECORDER)" ]]; then
  step "停用 AWS Config 記錄"
  run aws configservice stop-configuration-recorder --configuration-recorder-name default
  run aws configservice delete-delivery-channel --delivery-channel-name default
  run aws configservice delete-configuration-recorder --configuration-recorder-name default
fi
if t="$(state_get TRAIL_NAME)" && [[ -n "$t" ]]; then
  step "刪除 CloudTrail 線索 $t"
  run aws cloudtrail stop-logging --name "$t"
  run aws cloudtrail delete-trail --name "$t"
fi
if b="$(state_get LOG_BUCKET)" && [[ -n "$b" ]]; then
  step "刪除日誌儲存貯體 $b"
  empty_bucket "$b"; run aws s3api delete-bucket --bucket "$b"
fi
if [[ "$(state_get SECURITYHUB_ENABLED)" == "true" ]]; then
  step "停用 Security Hub CSPM"
  run aws securityhub disable-security-hub
fi
if d="$(state_get GUARDDUTY_DETECTOR)" && [[ -n "$d" ]]; then
  step "停用 GuardDuty（刪除偵測器與所有調查結果）"
  run aws guardduty delete-detector --detector-id "$d"
fi

# ---------- C. 資料保護 ----------
if b="$(state_get S3_BUCKET)" && [[ -n "$b" ]]; then
  step "刪除資料儲存貯體 $b"
  empty_bucket "$b"; run aws s3api delete-bucket --bucket "$b"
fi
if k="$(state_get KMS_KEY_ID)" && [[ -n "$k" ]]; then
  step "排程刪除 KMS 金鑰 $k（7 天等待期，期間可 cancel-key-deletion）"
  run aws kms delete-alias --alias-name "alias/${PREFIX}-customer-pii-key"
  run aws kms schedule-key-deletion --key-id "$k" --pending-window-in-days 7
fi

# ---------- B. 身分 ----------
if r="$(state_get IAM_ROLE)" && [[ -n "$r" ]]; then
  step "刪除 IAM 角色 $r"
  run aws iam detach-role-policy --role-name "$r" --policy-arn arn:aws:iam::aws:policy/SecurityAudit
  run aws iam delete-role --role-name "$r"
fi
if a="$(state_get ACCESS_ANALYZER)" && [[ -n "$a" ]]; then
  step "刪除 Access Analyzer $a"
  run aws accessanalyzer delete-analyzer --analyzer-name "$a"
fi
if [[ "$(state_get PASSWORD_POLICY_CHANGED)" == "true" ]]; then
  step "還原密碼政策"
  if [[ -f "$STATE_DIR/password-policy.backup.json" ]]; then
    p="$(jq '.PasswordPolicy' "$STATE_DIR/password-policy.backup.json")"
    args=(--minimum-password-length "$(jq .MinimumPasswordLength <<<"$p")")
    [[ "$(jq .RequireUppercaseCharacters <<<"$p")" == true ]] && args+=(--require-uppercase-characters)
    [[ "$(jq .RequireLowercaseCharacters <<<"$p")" == true ]] && args+=(--require-lowercase-characters)
    [[ "$(jq .RequireNumbers <<<"$p")" == true ]] && args+=(--require-numbers)
    [[ "$(jq .RequireSymbols <<<"$p")" == true ]] && args+=(--require-symbols)
    [[ "$(jq .AllowUsersToChangePassword <<<"$p")" == true ]] && args+=(--allow-users-to-change-password)
    [[ "$(jq '.MaxPasswordAge // 0' <<<"$p")" != 0 ]] && args+=(--max-password-age "$(jq .MaxPasswordAge <<<"$p")")
    [[ "$(jq '.PasswordReusePrevention // 0' <<<"$p")" != 0 ]] && args+=(--password-reuse-prevention "$(jq .PasswordReusePrevention <<<"$p")")
    run aws iam update-account-password-policy "${args[@]}"
  else
    run aws iam delete-account-password-policy
  fi
fi

# ---------- A. Landing Zone ----------
for key in SCP_PROTECT SCP_REGION; do
  pid="$(state_get "$key")"; [[ -n "$pid" ]] || continue
  step "解除並刪除 SCP $pid"
  for t in $(aws organizations list-targets-for-policy --policy-id "$pid" --query 'Targets[].TargetId' --output text 2>/dev/null); do
    run aws organizations detach-policy --policy-id "$pid" --target-id "$t"
  done
  run aws organizations delete-policy --policy-id "$pid"
done
for key in $(grep -o '^OU_[A-Za-z_]*' "$STATE_FILE" || true); do
  step "刪除 OU（必須已無帳號）：$key"
  run aws organizations delete-organizational-unit --organizational-unit-id "$(state_get "$key")"
done
[[ "$(state_get ORG_CREATED)" == "true" ]] && warn "組織由本專案建立，但不會自動刪除；如需刪除請於主控台確認後手動處理"

mv "$STATE_FILE" "$STATE_FILE.done-$(date +%Y%m%d%H%M%S)"
ok "清理完成。狀態檔已封存。"
