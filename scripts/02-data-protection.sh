#!/usr/bin/env bash
# 模組 C｜資料保護
#   101：KMS 客戶管理金鑰（CMK）＋自動輪換、S3 加密桶（SSE-KMS、版本控制、封鎖公開）
#   102：拒絕非 HTTPS 的儲存貯體政策、帳號層級封鎖公開存取
#
# 用法：./scripts/02-data-protection.sh [kms|s3|bucket-policy|account-bpa|all]
# 費用：CMK 約每月 1 美元；空的 S3 桶幾乎不計費。
source "$(dirname "$0")/lib/common.sh"
ensure_aws
POL_DIR="$(dirname "$0")/policies"
KEY_ALIAS="alias/${PREFIX}-customer-pii-key"
BUCKET="${BUCKET:-${PREFIX}-customer-docs-${ACCOUNT_ID:(-6)}-${AWS_REGION}}"

kms() {
  step "Step 1–10：建立 CMK $KEY_ALIAS 並啟用自動輪換"
  local key_id
  key_id="$(aws kms list-aliases --query "Aliases[?AliasName=='${KEY_ALIAS}'].TargetKeyId | [0]" --output text)"
  if [[ "$key_id" != "None" && -n "$key_id" ]]; then
    ok "金鑰已存在：$key_id"
  else
    confirm "建立 KMS 對稱金鑰（約每月 1 美元）？" || { warn "略過"; return; }
    key_id="$(aws kms create-key \
      --description "CMK for customer PII data (${PREFIX})" \
      --key-spec SYMMETRIC_DEFAULT --key-usage ENCRYPT_DECRYPT \
      --tags "TagKey=$TAG_KEY,TagValue=$TAG_VALUE" "TagKey=DataClassification,TagValue=Confidential-PII" \
      --query KeyMetadata.KeyId --output text)"
    aws kms create-alias --alias-name "$KEY_ALIAS" --target-key-id "$key_id"
    ok "已建立金鑰 $key_id"
  fi
  aws kms enable-key-rotation --key-id "$key_id" --rotation-period-in-days 365
  ok "自動輪換：$(aws kms get-key-rotation-status --key-id "$key_id" --query KeyRotationEnabled --output text)"
  state_set KMS_KEY_ID "$key_id"
}

s3() {
  step "Step 11–20：建立加密 S3 儲存貯體 $BUCKET"
  local key_id; key_id="$(state_get KMS_KEY_ID)"
  [[ -n "$key_id" ]] || die "請先執行：$0 kms"
  if aws s3api head-bucket --bucket "$BUCKET" 2>/dev/null; then
    ok "儲存貯體已存在"
  else
    confirm "建立儲存貯體 $BUCKET？" || { warn "略過"; return; }
    if [[ "$AWS_REGION" == "us-east-1" ]]; then
      aws s3api create-bucket --bucket "$BUCKET" >/dev/null
    else
      aws s3api create-bucket --bucket "$BUCKET" \
        --create-bucket-configuration "LocationConstraint=$AWS_REGION" >/dev/null
    fi
    state_set S3_BUCKET "$BUCKET"
  fi
  aws s3api put-public-access-block --bucket "$BUCKET" --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
  aws s3api put-bucket-ownership-controls --bucket "$BUCKET" \
    --ownership-controls 'Rules=[{ObjectOwnership=BucketOwnerEnforced}]'
  aws s3api put-bucket-versioning --bucket "$BUCKET" --versioning-configuration Status=Enabled
  aws s3api put-bucket-encryption --bucket "$BUCKET" --server-side-encryption-configuration \
    "{\"Rules\":[{\"ApplyServerSideEncryptionByDefault\":{\"SSEAlgorithm\":\"aws:kms\",\"KMSMasterKeyID\":\"${key_id}\"},\"BucketKeyEnabled\":true}]}"
  aws s3api put-bucket-tagging --bucket "$BUCKET" --tagging "TagSet=[{Key=$TAG_KEY,Value=$TAG_VALUE}]"
  ok "封鎖公開存取、ACL 停用、版本控制、SSE-KMS（儲存貯體金鑰）皆已設定"
}

bucket_policy() {
  step "Step 21：套用「拒絕非 HTTPS」儲存貯體政策"
  aws s3api head-bucket --bucket "$BUCKET" 2>/dev/null || die "儲存貯體不存在，請先執行：$0 s3"
  local policy
  policy="$(sed "s/BUCKET_NAME/${BUCKET}/g" "$POL_DIR/s3-deny-insecure-transport.json")"
  aws s3api put-bucket-policy --bucket "$BUCKET" --policy "$policy"
  ok "已套用。限定 VPC Endpoint 的版本請參考 policies/s3-restrict-to-vpce.json"
}

account_bpa() {
  step "Step 22：開啟帳號層級 S3 封鎖公開存取"
  warn "此設定影響帳號內所有儲存貯體；若有以 S3 直接對外提供的網站將無法存取"
  confirm "確定開啟帳號層級封鎖公開存取？" || { warn "略過"; return; }
  aws s3control put-public-access-block --account-id "$ACCOUNT_ID" --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
  ok "帳號層級封鎖公開存取已開啟（清理腳本不會自動關閉，建議保留）"
}

case "${1:-all}" in
  kms) kms ;;
  s3) s3 ;;
  bucket-policy) bucket_policy ;;
  account-bpa) account_bpa ;;
  all) kms; s3; bucket_policy ;;
  *) die "未知參數：$1" ;;
esac
