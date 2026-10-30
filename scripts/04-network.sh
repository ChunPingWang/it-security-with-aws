#!/usr/bin/env bash
# 模組 E｜網路隔離與防護
#   101：只含私有子網路的 VPC、S3 閘道端點、最小開放 Security Group、VPC Flow Logs
#   102：WAF Web ACL（IP 信譽＋Core rule set，Count 模式）
#
# 用法：./scripts/04-network.sh [vpc|sg|flowlogs|waf|all]
# 費用：VPC、子網路、S3 閘道端點免費；Flow Logs 依 CloudWatch Logs 用量；
#       WAF Web ACL 每月約 5 美元＋每條規則費用（未關聯資源也會計費）。
source "$(dirname "$0")/lib/common.sh"
ensure_aws
VPC_CIDR="${VPC_CIDR:-10.20.0.0/16}"
NAME="${PREFIX}-corebank"

tag_spec() { printf 'ResourceType=%s,Tags=[{Key=Name,Value=%s},{Key=%s,Value=%s}]' "$1" "$2" "$TAG_KEY" "$TAG_VALUE"; }

vpc() {
  step "Step 1–4：建立只有私有子網路的 VPC（$VPC_CIDR，2 個 AZ，無 IGW / NAT）"
  local vpc_id; vpc_id="$(state_get VPC_ID)"
  if [[ -n "$vpc_id" ]]; then ok "VPC 已存在：$vpc_id"; return; fi
  confirm "建立 VPC $NAME？" || { warn "略過"; return; }
  vpc_id="$(aws ec2 create-vpc --cidr-block "$VPC_CIDR" \
    --tag-specifications "$(tag_spec vpc "${NAME}-vpc")" --query Vpc.VpcId --output text)"
  state_set VPC_ID "$vpc_id"
  aws ec2 modify-vpc-attribute --vpc-id "$vpc_id" --enable-dns-support '{"Value":true}'
  aws ec2 modify-vpc-attribute --vpc-id "$vpc_id" --enable-dns-hostnames '{"Value":true}'

  local base="${VPC_CIDR%.*.*}" azs i az subnet rtb rtbs=()   # 例：10.20
  mapfile -t azs < <(aws ec2 describe-availability-zones --filters Name=state,Values=available \
    --query 'AvailabilityZones[0:2].ZoneName' --output text | tr '\t' '\n')
  for i in 0 1; do
    az="${azs[$i]}"
    subnet="$(aws ec2 create-subnet --vpc-id "$vpc_id" --availability-zone "$az" \
      --cidr-block "${base}.$((128 + i * 16)).0/20" \
      --tag-specifications "$(tag_spec subnet "${NAME}-subnet-private$((i+1))-${az}")" \
      --query Subnet.SubnetId --output text)"
    rtb="$(aws ec2 create-route-table --vpc-id "$vpc_id" \
      --tag-specifications "$(tag_spec route-table "${NAME}-rtb-private$((i+1))-${az}")" \
      --query RouteTable.RouteTableId --output text)"
    aws ec2 associate-route-table --route-table-id "$rtb" --subnet-id "$subnet" >/dev/null
    rtbs+=("$rtb")
    info "私有子網路 $subnet（$az）→ 路由表 $rtb"
  done
  local vpce
  vpce="$(aws ec2 create-vpc-endpoint --vpc-id "$vpc_id" --vpc-endpoint-type Gateway \
    --service-name "com.amazonaws.${AWS_REGION}.s3" --route-table-ids "${rtbs[@]}" \
    --tag-specifications "$(tag_spec vpc-endpoint "${NAME}-vpce-s3")" \
    --query VpcEndpoint.VpcEndpointId --output text)"
  state_set VPCE_ID "$vpce"
  ok "VPC $vpc_id 建立完成，S3 閘道端點 $vpce（可填入 policies/s3-restrict-to-vpce.json）"
}

sg() {
  step "Step 5–8：建立應用層 Security Group（只允許 VPC 內 HTTPS，限縮出站）"
  local vpc_id; vpc_id="$(state_get VPC_ID)"; [[ -n "$vpc_id" ]] || die "請先執行：$0 vpc"
  local sg_id; sg_id="$(state_get SG_ID)"
  if [[ -n "$sg_id" ]]; then ok "SG 已存在：$sg_id"; return; fi
  sg_id="$(aws ec2 create-security-group --group-name "${NAME}-app-sg" \
    --description "Core banking app tier - HTTPS from VPC only" --vpc-id "$vpc_id" \
    --tag-specifications "$(tag_spec security-group "${NAME}-app-sg")" --query GroupId --output text)"
  state_set SG_ID "$sg_id"
  aws ec2 authorize-security-group-ingress --group-id "$sg_id" --ip-permissions \
    "IpProtocol=tcp,FromPort=443,ToPort=443,IpRanges=[{CidrIp=${VPC_CIDR},Description=Internal HTTPS only}]" >/dev/null
  # 102：移除預設「全部出站」，只允許到 VPC 內與 S3 前綴清單的 HTTPS
  aws ec2 revoke-security-group-egress --group-id "$sg_id" \
    --ip-permissions 'IpProtocol=-1,IpRanges=[{CidrIp=0.0.0.0/0}]' >/dev/null
  local pl; pl="$(aws ec2 describe-managed-prefix-lists \
    --filters "Name=prefix-list-name,Values=com.amazonaws.${AWS_REGION}.s3" --query 'PrefixLists[0].PrefixListId' --output text)"
  aws ec2 authorize-security-group-egress --group-id "$sg_id" --ip-permissions \
    "IpProtocol=tcp,FromPort=443,ToPort=443,IpRanges=[{CidrIp=${VPC_CIDR}}],PrefixListIds=[{PrefixListId=${pl},Description=S3 via gateway endpoint}]" >/dev/null
  ok "SG $sg_id：入站 443/${VPC_CIDR}；出站僅 443 到 VPC 與 S3"
}

flowlogs() {
  step "Step 9：開啟 VPC Flow Logs（ACCEPT＋REJECT → CloudWatch Logs，保存 90 天）"
  local vpc_id; vpc_id="$(state_get VPC_ID)"; [[ -n "$vpc_id" ]] || die "請先執行：$0 vpc"
  local lg="/${PREFIX}/vpc-flow-logs" role="${PREFIX}-vpc-flowlogs-role"
  aws logs create-log-group --log-group-name "$lg" 2>/dev/null || true
  aws logs put-retention-policy --log-group-name "$lg" --retention-in-days 90
  state_set FLOWLOG_GROUP "$lg"
  if ! aws iam get-role --role-name "$role" >/dev/null 2>&1; then
    aws iam create-role --role-name "$role" --assume-role-policy-document \
      '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"vpc-flow-logs.amazonaws.com"},"Action":"sts:AssumeRole"}]}' \
      --tags "Key=$TAG_KEY,Value=$TAG_VALUE" >/dev/null
    aws iam put-role-policy --role-name "$role" --policy-name flowlogs-to-cwl --policy-document \
      "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":[\"logs:CreateLogStream\",\"logs:PutLogEvents\",\"logs:DescribeLogStreams\"],\"Resource\":\"arn:aws:logs:${AWS_REGION}:${ACCOUNT_ID}:log-group:${lg}:*\"}]}"
    state_set FLOWLOG_ROLE "$role"
    sleep 10   # 等待 IAM 角色生效
  fi
  local fl
  fl="$(aws ec2 create-flow-logs --resource-type VPC --resource-ids "$vpc_id" --traffic-type ALL \
    --log-destination-type cloud-watch-logs --log-group-name "$lg" \
    --deliver-logs-permission-arn "arn:aws:iam::${ACCOUNT_ID}:role/${role}" \
    --query 'FlowLogIds[0]' --output text)"
  state_set FLOWLOG_ID "$fl"
  ok "Flow Log $fl 已建立。銀行正式環境建議改送到 Log Archive 帳號的 S3"
}

waf() {
  step "Step 10–13：建立 WAF Web ACL（區域型，Count 模式觀察）"
  confirm "建立 WAF Web ACL（每月約 5 美元＋規則費用）？" || { warn "略過"; return; }
  local name="${PREFIX}-ebanking-waf" out
  out="$(aws wafv2 create-web-acl --name "$name" --scope REGIONAL \
    --default-action Allow={} \
    --visibility-config "SampledRequestsEnabled=true,CloudWatchMetricsEnabled=true,MetricName=${name}" \
    --rules "$(cat "$(dirname "$0")/policies/waf-managed-rules.json")" \
    --tags "Key=$TAG_KEY,Value=$TAG_VALUE" --output json)"
  state_set WAF_NAME "$name"
  state_set WAF_ID "$(jq -r .Summary.Id <<<"$out")"
  ok "Web ACL 已建立（規則為 Count 模式）。觀察無誤擋後再改為 Block，並關聯到 ALB / API Gateway"
}

case "${1:-all}" in
  vpc) vpc ;;
  sg) sg ;;
  flowlogs) flowlogs ;;
  waf) waf ;;
  all) vpc; sg; flowlogs ;;
  *) die "未知參數：$1" ;;
esac
