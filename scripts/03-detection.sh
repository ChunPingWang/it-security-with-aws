#!/usr/bin/env bash
# 模組 D｜稽核與威脅偵測
#   101：CloudTrail 線索（多區域＋日誌檔驗證）、AWS Config 記錄與受管規則
#   102：GuardDuty（含範例調查結果）、Security Hub CSPM（FSBP＋PCI DSS v4.0.1）
#
# 用法：./scripts/03-detection.sh [events|trail|config|guardduty|securityhub|all]
# 費用：GuardDuty / Security Hub 首次啟用有 30 天免費試用；Config 依記錄項目計費；
#       Trail 第一份管理事件免費，S3 儲存另計。
source "$(dirname "$0")/lib/common.sh"
ensure_aws
POL_DIR="$(dirname "$0")/policies"
LOG_BUCKET="${LOG_BUCKET:-${PREFIX}-audit-logs-${ACCOUNT_ID:(-6)}-${AWS_REGION}}"
TRAIL_NAME="${PREFIX}-org-audit-trail"

events() {
  step "Step 1–2：查詢 CloudTrail 事件歷史（最近 20 筆寫入事件，唯讀）"
  aws cloudtrail lookup-events --max-results 50 \
    --lookup-attributes AttributeKey=ReadOnly,AttributeValue=false \
    --query 'Events[0:20].[EventTime,EventName,Username,EventSource]' --output table
}

log_bucket() {
  if ! aws s3api head-bucket --bucket "$LOG_BUCKET" 2>/dev/null; then
    confirm "建立日誌儲存貯體 $LOG_BUCKET？" || die "需要日誌儲存貯體"
    if [[ "$AWS_REGION" == "us-east-1" ]]; then
      aws s3api create-bucket --bucket "$LOG_BUCKET" >/dev/null
    else
      aws s3api create-bucket --bucket "$LOG_BUCKET" --create-bucket-configuration "LocationConstraint=$AWS_REGION" >/dev/null
    fi
    aws s3api put-public-access-block --bucket "$LOG_BUCKET" --public-access-block-configuration \
      BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
    aws s3api put-bucket-versioning --bucket "$LOG_BUCKET" --versioning-configuration Status=Enabled
    aws s3api put-bucket-encryption --bucket "$LOG_BUCKET" --server-side-encryption-configuration \
      '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
    aws s3api put-bucket-tagging --bucket "$LOG_BUCKET" --tagging "TagSet=[{Key=$TAG_KEY,Value=$TAG_VALUE}]"
    state_set LOG_BUCKET "$LOG_BUCKET"
  fi
  local policy
  policy="$(sed -e "s/BUCKET_NAME/${LOG_BUCKET}/g" -e "s/ACCOUNT_ID/${ACCOUNT_ID}/g" \
               -e "s/REGION/${AWS_REGION}/g" -e "s/TRAIL_NAME/${TRAIL_NAME}/g" \
               "$POL_DIR/log-bucket-cloudtrail-config.json")"
  aws s3api put-bucket-policy --bucket "$LOG_BUCKET" --policy "$policy"
}

trail() {
  step "Step 3–6：建立多區域 CloudTrail 線索（日誌檔驗證、客戶資料桶資料事件）"
  if aws cloudtrail get-trail --name "$TRAIL_NAME" >/dev/null 2>&1; then ok "線索已存在"; return; fi
  confirm "建立線索 $TRAIL_NAME（會持續寫入日誌到 S3）？" || { warn "略過"; return; }
  log_bucket
  aws cloudtrail create-trail --name "$TRAIL_NAME" --s3-bucket-name "$LOG_BUCKET" \
    --is-multi-region-trail --enable-log-file-validation \
    --tags-list "Key=$TAG_KEY,Value=$TAG_VALUE" >/dev/null
  local data_bucket; data_bucket="$(state_get S3_BUCKET)"
  if [[ -n "$data_bucket" ]]; then
    aws cloudtrail put-event-selectors --trail-name "$TRAIL_NAME" --advanced-event-selectors "[
      {\"Name\":\"Management events\",\"FieldSelectors\":[{\"Field\":\"eventCategory\",\"Equals\":[\"Management\"]}]},
      {\"Name\":\"Customer docs data events\",\"FieldSelectors\":[
        {\"Field\":\"eventCategory\",\"Equals\":[\"Data\"]},
        {\"Field\":\"resources.type\",\"Equals\":[\"AWS::S3::Object\"]},
        {\"Field\":\"resources.ARN\",\"StartsWith\":[\"arn:aws:s3:::${data_bucket}/\"]}]}]" >/dev/null
    info "已針對 $data_bucket 記錄 S3 物件層級資料事件"
  fi
  aws cloudtrail start-logging --name "$TRAIL_NAME"
  state_set TRAIL_NAME "$TRAIL_NAME"
  ok "線索已啟動。驗證日誌完整性：aws cloudtrail validate-logs --trail-arn <ARN> --start-time <時間>"
}

config() {
  step "Step 7–8：啟用 AWS Config 並加入受管規則"
  confirm "啟用 AWS Config 記錄（依記錄項目計費）？" || { warn "略過"; return; }
  log_bucket
  aws iam create-service-linked-role --aws-service-name config.amazonaws.com >/dev/null 2>&1 || true
  local role="arn:aws:iam::${ACCOUNT_ID}:role/aws-service-role/config.amazonaws.com/AWSServiceRoleForConfig"
  aws configservice put-configuration-recorder \
    --configuration-recorder "name=default,roleARN=${role}" \
    --recording-group allSupported=true,includeGlobalResourceTypes=false
  aws configservice put-delivery-channel --delivery-channel "name=default,s3BucketName=${LOG_BUCKET}"
  aws configservice start-configuration-recorder --configuration-recorder-name default
  state_set CONFIG_RECORDER default
  local rule
  for rule in S3_BUCKET_PUBLIC_READ_PROHIBITED S3_BUCKET_SSL_REQUESTS_ONLY ENCRYPTED_VOLUMES \
              ROOT_ACCOUNT_MFA_ENABLED CMK_BACKING_KEY_ROTATION_ENABLED VPC_FLOW_LOGS_ENABLED; do
    local name; name="${PREFIX}-$(tr '[:upper:]_' '[:lower:]-' <<<"$rule")"
    aws configservice put-config-rule --config-rule \
      "{\"ConfigRuleName\":\"${name}\",\"Source\":{\"Owner\":\"AWS\",\"SourceIdentifier\":\"${rule}\"}}"
    info "已加入規則 $name"
  done
  state_set CONFIG_RULES true
  ok "AWS Config 已啟用"
}

guardduty() {
  step "Step 9–13：啟用 GuardDuty 並產生範例調查結果"
  local det; det="$(aws guardduty list-detectors --query 'DetectorIds[0]' --output text)"
  if [[ "$det" == "None" || -z "$det" ]]; then
    confirm "啟用 GuardDuty（首次 30 天免費試用）？" || { warn "略過"; return; }
    det="$(aws guardduty create-detector --enable --finding-publishing-frequency FIFTEEN_MINUTES \
      --tags "$TAG_KEY=$TAG_VALUE" --query DetectorId --output text)"
    state_set GUARDDUTY_DETECTOR "$det"
    ok "GuardDuty 已啟用：$det"
  else
    ok "GuardDuty 已存在：$det（清理時不會停用既有偵測器）"
  fi
  if confirm "產生範例調查結果（標題前綴 [SAMPLE]，不影響實際資源）？"; then
    aws guardduty create-sample-findings --detector-id "$det"
    sleep 10
    aws guardduty get-findings-statistics --detector-id "$det" \
      --finding-statistic-types COUNT_BY_SEVERITY --output json | jq '.FindingStatistics'
  fi
}

securityhub() {
  step "Step 14–17：啟用 Security Hub CSPM（FSBP＋PCI DSS v4.0.1）"
  if aws securityhub describe-hub >/dev/null 2>&1; then
    ok "Security Hub 已啟用（清理時不會停用既有設定）"
  else
    confirm "啟用 Security Hub CSPM（首次 30 天免費試用；控制項需 AWS Config）？" || { warn "略過"; return; }
    aws securityhub enable-security-hub --no-enable-default-standards --tags "$TAG_KEY=$TAG_VALUE"
    state_set SECURITYHUB_ENABLED true
  fi
  local arns
  arns="$(aws securityhub describe-standards --output json | jq -c '[.Standards[]
          | select(.StandardsArn | test("aws-foundational-security-best-practices/v/1.0.0|pci-dss/v/4.0.1"))
          | {StandardsArn}]')"
  info "啟用標準：$(jq -r '[.[].StandardsArn | split("/")[-3:] | join("/")] | join(", ")' <<<"$arns")"
  aws securityhub batch-enable-standards --standards-subscription-requests "$arns" >/dev/null
  ok "已送出啟用；最多約 2 小時後才會出現控制項結果"
  info "最新 5 筆調查結果："
  aws securityhub get-findings --max-results 5 \
    --query 'Findings[].[Severity.Label,Title]' --output table || true
}

case "${1:-all}" in
  events) events ;;
  trail) trail ;;
  config) config ;;
  guardduty) guardduty ;;
  securityhub) securityhub ;;
  all) events; guardduty; securityhub ;;
  *) die "未知參數：$1" ;;
esac
