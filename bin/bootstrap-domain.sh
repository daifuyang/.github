#!/usr/bin/env bash
# bootstrap-domain.sh — 一键引导新域名
#
# 用法:
#   ./bin/bootstrap-domain.sh <domain> <root_domain>
#   ./bin/bootstrap-domain.sh dock.zerocmf.com zerocmf.com
#
# 作用:
#   1. acme.sh 签 Let's Encrypt 证书 (dns_ali 验证)
#   2. 上传到阿里云 CAS (命名 <domain 中 . 改 ->, 例如 dock-zerocmf-com-auto)
#   3. 加 DNS CNAME 记录 → FC 网关
#   4. 输出 cert name 和 s.yaml 需要的字段
#
# 前置:
#   - aic CLI 已装, 当前用户有阿里云 DNS 写权限
#   - acme.sh 已装 (curl https://get.acme.sh | sh)
#   - 阿里云 AccessKey 已配到 env-config (env 会读)
#   - 已经在阿里云 DNS 托管 <root_domain> 域

set -euo pipefail

if [ $# -lt 2 ]; then
  echo "Usage: $0 <domain> <root_domain>"
  echo "  e.g. $0 dock.zerocmf.com zerocmf.com"
  exit 1
fi

DOMAIN="$1"
ROOT_DOMAIN="$2"

# 计算 cert name: dock.zerocmf.com → dock-zerocmf-com-auto
CERT_NAME=$(echo "$DOMAIN" | tr '.' '-' | sed 's/$/-auto/')
RR=$(echo "$DOMAIN" | sed "s/\.${ROOT_DOMAIN}$//")

ACCOUNT_ID=$(aliyun sts GetCallerIdentity --profile fc --region cn-shanghai 2>/dev/null \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['AccountId'])")

FC_GATEWAY="${ACCOUNT_ID}.cn-shanghai.fc.aliyuncs.com"

echo "=========================================="
echo " Domain : $DOMAIN"
echo " RR     : $RR.$ROOT_DOMAIN"
echo " Cert   : $CERT_NAME"
echo " Gateway: $FC_GATEWAY"
echo "=========================================="
echo ""

# 1. 签证书
echo "[1/3] 签 Let's Encrypt 证书..."
~/.acme.sh/acme.sh --issue --dns dns_ali -d "$DOMAIN" --keylength 2048 || {
  echo "ERROR: 证书签发失败"
  exit 1
}

# 2. 上传到 CAS
echo ""
echo "[2/3] 上传到阿里云 CAS..."
# 用 enterprise profile — dns user 有 CAS 写权限
# 注意: aic aliyun-cert:upload 签名是 <name> <certFile> <keyFile>, 不需要 <domain>
aic aliyun-cert:upload -p enterprise "$CERT_NAME" \
  "$HOME/.acme.sh/$DOMAIN/fullchain.cer" \
  "$HOME/.acme.sh/$DOMAIN/$DOMAIN.key" || {
  echo "ERROR: 上传 CAS 失败 (可能已存在同名证书, 可忽略)"
}

# 3. 加 DNS
echo ""
echo "[3/3] 加 DNS CNAME..."
# 检查是否已有同名记录
EXISTING=$(aic dns:list "$ROOT_DOMAIN" 2>/dev/null | python3 -c "
import sys, json
d = json.load(sys.stdin)
for r in d.get('DomainRecords', {}).get('Record', []):
    if r.get('RR') == '$RR':
        print(r.get('RecordId'), r.get('Type'))
        break
" 2>/dev/null || echo "")

if [ -n "$EXISTING" ]; then
  echo "  已存在记录: $EXISTING (跳过添加, 如需更换请手动删除)"
else
  aic dns:add "$ROOT_DOMAIN" "$RR" CNAME "$FC_GATEWAY" --ttl 600
fi

echo ""
echo "=========================================="
echo " 完成! 在 s.yaml 中填:"
echo ""
echo "   vars:"
echo "     customDomain: $DOMAIN"
echo "     certName: $CERT_NAME"
echo "=========================================="
echo ""
echo "接下来:"
echo "  1. 等待 Let's Encrypt 验证 (1-2 分钟)"
echo "  2. 等待 FC 边缘节点 DNS 同步 (1-2 分钟)"
echo "  3. curl -ksS https://$DOMAIN 验证"
