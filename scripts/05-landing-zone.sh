#!/usr/bin/env bash
# 模組 A｜Landing Zone（必須在 Organizations「管理帳號」執行）
#   status      ：唯讀，顯示組織、OU 與 SCP 狀態
#   create-org  ：建立組織（所有功能模式）—— 管理帳號之後無法更換，請審慎
#   create-ous  ：建立銀行參考 OU 結構（Security / Infrastructure / Workloads-Prod / Workloads-NonProd / Sandbox / Policy-Staging）
#   scp         ：建立兩個 SCP 並掛到 Policy-Staging OU 驗證
#                 - 保護稽核基線（禁止關閉 CloudTrail / GuardDuty / Security Hub / Config）
#                 - 區域拒絕（只允許 ALLOWED_REGIONS）
#   promote-scp ：驗證無誤後，把 SCP 掛到 Workloads-Prod / Workloads-NonProd
#
# Control Tower 的完整部署建議用主控台（見 docs/01-landing-zone.md），
# 或以 `aws controltower create-landing-zone --manifest file://...` 搭配 policies/control-tower-manifest.json。
source "$(dirname "$0")/lib/common.sh"
ensure_aws
POL_DIR="$(dirname "$0")/policies"
ALLOWED_REGIONS="${ALLOWED_REGIONS:-eu-central-1,eu-west-1}"
OUS=(Security Infrastructure Workloads-Prod Workloads-NonProd Sandbox Policy-Staging)

org_json() { aws organizations describe-organization --output json 2>/dev/null; }
root_id()  { aws organizations list-roots --query 'Roots[0].Id' --output text; }
ou_id()    { aws organizations list-organizational-units-for-parent --parent-id "$(root_id)" \
               --query "OrganizationalUnits[?Name=='$1'].Id | [0]" --output text; }
need_mgmt() {
  local org; org="$(org_json)" || die "尚未建立組織：先執行 $0 create-org"
  [[ "$(jq -r .Organization.MasterAccountId <<<"$org")" == "$ACCOUNT_ID" ]] || die "請在管理帳號執行"
}

status() {
  step "組織狀態（唯讀）"
  local org; org="$(org_json)" || { warn "此帳號未加入 AWS Organizations"; return; }
  info "FeatureSet：$(jq -r .Organization.FeatureSet <<<"$org")"
  info "管理帳號：$( [[ "$(jq -r .Organization.MasterAccountId <<<"$org")" == "$ACCOUNT_ID" ]] && echo 是目前帳號 || echo 其他帳號 )"
  aws organizations list-organizational-units-for-parent --parent-id "$(root_id)" \
    --query 'OrganizationalUnits[].[Name,Id]' --output table 2>/dev/null || true
  aws organizations list-policies --filter SERVICE_CONTROL_POLICY \
    --query 'Policies[].[Name,AwsManaged]' --output table 2>/dev/null || true
}

create_org() {
  step "模組 A Step 1：建立 AWS Organizations（所有功能）"
  if org_json >/dev/null; then ok "已在組織中"; return; fi
  warn "目前帳號將成為管理帳號，之後無法更換；建議使用不跑工作負載的乾淨帳號。"
  confirm "確定建立組織？" || { warn "略過"; return; }
  aws organizations create-organization --feature-set ALL >/dev/null
  aws organizations enable-policy-type --root-id "$(root_id)" --policy-type SERVICE_CONTROL_POLICY >/dev/null || true
  state_set ORG_CREATED true
  ok "組織已建立並啟用 SCP"
}

create_ous() {
  step "模組 A：建立銀行參考 OU 結構"
  need_mgmt
  local n id root; root="$(root_id)"
  for n in "${OUS[@]}"; do
    id="$(ou_id "$n")"
    if [[ "$id" != "None" && -n "$id" ]]; then ok "OU 已存在：$n ($id)"; continue; fi
    id="$(aws organizations create-organizational-unit --parent-id "$root" --name "$n" \
          --tags "Key=$TAG_KEY,Value=$TAG_VALUE" --query OrganizationalUnit.Id --output text)"
    state_set "OU_${n//-/_}" "$id"
    ok "建立 OU：$n ($id)"
  done
}

create_policy() {
  local name="$1" file="$2" desc="$3" id content
  id="$(aws organizations list-policies --filter SERVICE_CONTROL_POLICY \
        --query "Policies[?Name=='$name'].Id | [0]" --output text)"
  if [[ "$id" == "None" || -z "$id" ]]; then
    content="$(jq -c . "$file")"
    id="$(aws organizations create-policy --type SERVICE_CONTROL_POLICY --name "$name" \
          --description "$desc" --content "$content" --tags "Key=$TAG_KEY,Value=$TAG_VALUE" \
          --query Policy.PolicySummary.Id --output text)"
  fi
  echo "$id"
}

attach() {
  local pid="$1" target="$2"
  aws organizations attach-policy --policy-id "$pid" --target-id "$target" 2>/dev/null \
    && ok "已掛載 $pid → $target" || info "$pid 已掛載於 $target"
}

scp() {
  step "模組 B：建立 SCP 並掛到 Policy-Staging OU"
  need_mgmt
  local staging; staging="$(ou_id Policy-Staging)"
  [[ "$staging" != "None" && -n "$staging" ]] || die "找不到 Policy-Staging OU，先執行 $0 create-ous"
  local regions_json tmp p1 p2
  regions_json="$(jq -cn --arg r "$ALLOWED_REGIONS" '$r | split(",")')"
  tmp="$(mktemp)"
  jq --argjson r "$regions_json" '(.Statement[] | select(.Sid=="DenyOutsideApprovedRegions")
        .Condition.StringNotEquals["aws:RequestedRegion"]) = $r' "$POL_DIR/scp-region-deny.json" >"$tmp"
  p1="$(create_policy "${PREFIX}-protect-audit-baseline" "$POL_DIR/scp-protect-audit-baseline.json" "Deny disabling CloudTrail/GuardDuty/SecurityHub/Config and root usage")"
  p2="$(create_policy "${PREFIX}-region-deny" "$tmp" "Deny actions outside ${ALLOWED_REGIONS}")"
  rm -f "$tmp"
  state_set SCP_PROTECT "$p1"; state_set SCP_REGION "$p2"
  attach "$p1" "$staging"; attach "$p2" "$staging"
  info "請把測試帳號移入 Policy-Staging 驗證，再執行：$0 promote-scp"
}

promote_scp() {
  step "把已驗證的 SCP 掛到正式 / 非正式工作負載 OU"
  need_mgmt
  local p1 p2 ou id; p1="$(state_get SCP_PROTECT)"; p2="$(state_get SCP_REGION)"
  [[ -n "$p1" && -n "$p2" ]] || die "請先執行 $0 scp"
  confirm "SCP 會立即影響這些 OU 下的所有帳號，確定？" || { warn "略過"; return; }
  for ou in Workloads-Prod Workloads-NonProd; do
    id="$(ou_id "$ou")"; attach "$p1" "$id"; attach "$p2" "$id"
  done
}

case "${1:-status}" in
  status) status ;;
  create-org) create_org ;;
  create-ous) create_ous ;;
  scp) scp ;;
  promote-scp) promote_scp ;;
  *) die "未知參數：$1" ;;
esac
