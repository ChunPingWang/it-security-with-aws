#!/usr/bin/env bash
# Level 101｜唯讀健檢：不會建立或修改任何資源
# 對應教材：模組 B Step 1、模組 C Step 22、模組 D、F「本帳號實際發現」
#
# 用法：./scripts/00-check-baseline.sh
source "$(dirname "$0")/lib/common.sh"
ensure_aws

PASS=0; FAILS=0; WARNS=0
pass()  { ok "$*";   PASS=$((PASS+1)); }
bad()   { fail "$*"; FAILS=$((FAILS+1)); }
soft()  { warn "$*"; WARNS=$((WARNS+1)); }

step "B. 身分與權限"
summary="$(aws iam get-account-summary --output json)"
[[ "$(jq '.SummaryMap.AccountMFAEnabled' <<<"$summary")" == "1" ]] \
  && pass "Root 已啟用 MFA" || bad "Root 未啟用 MFA"
[[ "$(jq '.SummaryMap.AccountAccessKeysPresent' <<<"$summary")" == "0" ]] \
  && pass "Root 沒有存取金鑰" || bad "Root 仍有存取金鑰 → IAM → 根存取管理 → 停用並刪除"
users="$(jq '.SummaryMap.Users' <<<"$summary")"
[[ "$users" -le 1 ]] && pass "IAM 使用者數量：$users" || soft "IAM 使用者數量：$users（建議改用 Identity Center SSO）"

if pw="$(aws iam get-account-password-policy --output json 2>/dev/null)"; then
  len="$(jq '.PasswordPolicy.MinimumPasswordLength' <<<"$pw")"
  reuse="$(jq '.PasswordPolicy.PasswordReusePrevention // 0' <<<"$pw")"
  [[ "$len" -ge 14 ]] && pass "密碼最小長度 $len" || soft "密碼最小長度 $len（示範建議 14）"
  [[ "$reuse" -ge 24 ]] && pass "密碼重複使用防止 $reuse 組" || soft "密碼重複使用防止 $reuse 組（示範建議 24）"
else
  soft "未設定自訂密碼政策（使用 AWS 預設）"
fi

if aws accessanalyzer list-analyzers --output json | jq -e '.analyzers | length > 0' >/dev/null; then
  pass "IAM Access Analyzer 已建立"
else
  soft "此區域沒有 IAM Access Analyzer"
fi

step "C. 資料保護"
if bpa="$(aws s3control get-public-access-block --account-id "$ACCOUNT_ID" --output json 2>/dev/null)"; then
  if jq -e '.PublicAccessBlockConfiguration | [.[]] | all' <<<"$bpa" >/dev/null; then
    pass "帳號層級 S3 封鎖公開存取：四項全開"
  else
    bad "帳號層級 S3 封鎖公開存取：未全部開啟"
  fi
else
  bad "帳號層級 S3 封鎖公開存取：未設定（四項皆關閉）"
fi
ebs="$(aws ec2 get-ebs-encryption-by-default --query EbsEncryptionByDefault --output text)"
[[ "$ebs" == "True" ]] && pass "EBS 預設加密已開啟" || soft "EBS 預設加密未開啟（$AWS_REGION）"

step "D. 稽核與偵測"
trails="$(aws cloudtrail describe-trails --output json)"
ntrail="$(jq '.trailList | length' <<<"$trails")"
if [[ "$ntrail" -gt 0 ]]; then
  pass "CloudTrail 線索數：$ntrail"
  jq -e '.trailList | any(.LogFileValidationEnabled)' <<<"$trails" >/dev/null \
    && pass "至少一條線索已開啟日誌檔驗證" || soft "線索未開啟日誌檔驗證"
  jq -e '.trailList | any(.IsMultiRegionTrail)' <<<"$trails" >/dev/null \
    && pass "有多區域線索" || soft "沒有多區域線索"
else
  bad "沒有 CloudTrail 線索（事件歷史只保留 90 天）"
fi
recorders="$(aws configservice describe-configuration-recorder-status --output json)"
jq -e '.ConfigurationRecordersStatus | any(.recording)' <<<"$recorders" >/dev/null \
  && pass "AWS Config 正在記錄" || soft "AWS Config 未啟用"
det="$(aws guardduty list-detectors --query 'DetectorIds[0]' --output text)"
[[ "$det" != "None" && -n "$det" ]] && pass "GuardDuty 已啟用" || soft "GuardDuty 未啟用"
aws securityhub describe-hub >/dev/null 2>&1 && pass "Security Hub CSPM 已啟用" || soft "Security Hub CSPM 未啟用"

step "A. Landing Zone"
if org="$(aws organizations describe-organization --output json 2>/dev/null)"; then
  pass "屬於 AWS Organizations（FeatureSet=$(jq -r .Organization.FeatureSet <<<"$org")）"
else
  soft "未加入 AWS Organizations：無法使用 SCP、委派管理員、集中日誌"
fi

step "結果"
printf '通過 %d　警告 %d　失敗 %d\n' "$PASS" "$WARNS" "$FAILS"
[[ "$FAILS" -eq 0 ]]
