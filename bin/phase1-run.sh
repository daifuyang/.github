#!/usr/bin/env bash
# Phase 1 — 共享账号资源创建 (一次性)
# 前置: dns 子用户已临时挂 dns-bootstrap-perm 策略 (见 /tmp/dns-bootstrap-perm.json)
# 完成后: 该策略可保留 (Resource 限定为 github-actions-*, 无风险) 或移除

set -euo pipefail

ACCOUNT_ID="1650595695532785"
REGION="cn-shanghai"
OIDC_REGION="cn-hangzhou"
IDP_NAME="github-actions"
POLICY_NAME="GithubActionsFcPerm"
ROLE_NAME="GithubActionsFcDeployer"

cd "$(dirname "$0")/.."

echo "=== 1. 核查 OIDC IdP $IDP_NAME ==="
if ! aliyun ims GetOIDCProvider \
    --RegionId "$OIDC_REGION" \
    --OIDCProviderName "$IDP_NAME" \
    2>/dev/null; then
  echo "  IdP 不存在, 创建..."
  aliyun ims CreateOIDCProvider \
    --RegionId "$OIDC_REGION" \
    --OIDCProviderName "$IDP_NAME" \
    --IssuerUrl "https://token.actions.githubusercontent.com" \
    --ClientIds '["github-actions"]' \
    --Description "GitHub Actions OIDC federation for daifuyang org"
else
  echo "  IdP 已存在, 检查 ClientIds..."
  CURRENT=$(aliyun ims GetOIDCProvider \
    --RegionId "$OIDC_REGION" \
    --OIDCProviderName "$IDP_NAME" \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print(','.join(d.get('OIDCProvider',{}).get('ClientIds',[])))")
  echo "  当前 ClientIds: $CURRENT"
  if ! echo "$CURRENT" | grep -q "github-actions"; then
    echo "  添加 ClientId=github-actions..."
    aliyun ims AddClientIdToOIDCProvider \
      --RegionId "$OIDC_REGION" \
      --OIDCProviderName "$IDP_NAME" \
      --ClientId "github-actions"
  fi
fi

echo ""
echo "=== 2. 核查/创建权限策略 $POLICY_NAME ==="
if ! aliyun ram GetPolicy \
    --PolicyName "$POLICY_NAME" \
    --PolicyType Custom \
    2>/dev/null; then
  echo "  策略不存在, 创建..."
  DOC=$(cat /tmp/GithubActionsFcPerm.json | tr -d '\n')
  aliyun ram CreatePolicy \
    --PolicyName "$POLICY_NAME" \
    --PolicyDocument "$DOC" \
    --Description "Shared FC deploy permissions for GitHub Actions"
else
  echo "  策略已存在"
fi

echo ""
echo "=== 3. 核查/创建 RAM role $ROLE_NAME ==="
if ! aliyun ram GetRole \
    --RoleName "$ROLE_NAME" \
    2>/dev/null; then
  echo "  角色不存在, 创建..."
  DOC=$(cat /tmp/github-actions-trust-policy.json | tr -d '\n')
  aliyun ram CreateRole \
    --RoleName "$ROLE_NAME" \
    --AssumeRolePolicyDocument "$DOC" \
    --Description "GitHub Actions deploy role for daifuyang/* repos"
else
  echo "  角色已存在"
fi

echo ""
echo "=== 4. 附加权限策略到 role ==="
aliyun ram AttachPolicyToRole \
  --PolicyName "$POLICY_NAME" \
  --PolicyType Custom \
  --RoleName "$ROLE_NAME"

echo ""
echo "=== 5. 验证最终状态 ==="
echo "--- Role ARN ---"
ROLE_ARN=$(aliyun ram GetRole --RoleName "$ROLE_NAME" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['Role']['Arn'])")
echo "  $ROLE_ARN"

echo "--- Attached Policies ---"
aliyun ram ListPoliciesForRole --RoleName "$ROLE_NAME" \
  | python3 -c "import sys,json; d=json.load(sys.stdin); [print('  -', p['PolicyName'], '(', p['PolicyType'], ')') for p in d.get('Policies', {}).get('Policy', [])]"

echo "--- IdP info ---"
aliyun ims GetOIDCProvider \
  --RegionId "$OIDC_REGION" \
  --OIDCProviderName "$IDP_NAME" \
  | python3 -c "
import sys, json
d = json.load(sys.stdin)['OIDCProvider']
print('  IssuerUrl :', d.get('IssuerUrl'))
print('  ClientIds :', d.get('ClientIds'))
print('  Fingerprints count:', len(d.get('Fingerprints', [])))
"

echo ""
echo "=== Phase 1 完成 ==="
echo ""
echo "Org-level GitHub Secret:"
echo "  FC_DEPLOY_ROLE_ARN = $ROLE_ARN"
echo ""
echo "下一步:"
echo "  gh secret set FC_DEPLOY_ROLE_ARN --org daifuyang --body \"$ROLE_ARN\""
