#!/usr/bin/env bash
# Phase 1 — 共享账号资源创建 / 修复 (可重复运行)
# 前置: dns 子用户已挂 AliyunRAMFullAccess (完成后可撤)
# 完成后: 该策略可移除

set -euo pipefail

ACCOUNT_ID="1650595695532785"
REGION="cn-shanghai"
OIDC_REGION="cn-hangzhou"
IDP_NAME="github-actions"
IDP_AUDIENCE="github-actions"
POLICY_NAME="GithubActionsFcPerm"
ROLE_NAME="GithubActionsFcDeployer"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== 1. 核查/补建 OIDC IdP $IDP_NAME ==="
if ! aliyun ims GetOIDCProvider \
    --RegionId "$OIDC_REGION" \
    --OIDCProviderName "$IDP_NAME" \
    2>/dev/null; then
  echo "  IdP 不存在, 创建..."
  aliyun ims CreateOIDCProvider \
    --RegionId "$OIDC_REGION" \
    --OIDCProviderName "$IDP_NAME" \
    --IssuerUrl "https://token.actions.githubusercontent.com" \
    --ClientIds "[\"$IDP_AUDIENCE\"]" \
    --Description "GitHub Actions OIDC federation for daifuyang org (shared audience)"
else
  echo "  IdP 已存在, 核对 ClientIds..."
  CURRENT=$(aliyun ims GetOIDCProvider \
    --RegionId "$OIDC_REGION" \
    --OIDCProviderName "$IDP_NAME" \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print(','.join(d.get('OIDCProvider',{}).get('ClientIds',[])))")
  echo "  当前 ClientIds: $CURRENT"
  if ! echo "$CURRENT" | grep -q "$IDP_AUDIENCE"; then
    echo "  添加 ClientId=$IDP_AUDIENCE..."
    aliyun ims AddClientIdToOIDCProvider \
      --RegionId "$OIDC_REGION" \
      --OIDCProviderName "$IDP_NAME" \
      --ClientId "$IDP_AUDIENCE"
  else
    echo "  ClientId=$IDP_AUDIENCE 已在, 跳过"
  fi
fi

echo ""
echo "=== 2. 核查/补建权限策略 $POLICY_NAME ==="
if ! aliyun ram GetPolicy \
    --PolicyName "$POLICY_NAME" \
    --PolicyType Custom \
    2>/dev/null; then
  echo "  策略不存在, 创建..."
  DOC=$(cat "$SCRIPT_DIR/GithubActionsFcPerm.json" | tr -d '\n')
  aliyun ram CreatePolicy \
    --PolicyName "$POLICY_NAME" \
    --PolicyDocument "$DOC" \
    --Description "Shared FC deploy permissions for daifuyang/* GitHub Actions"
else
  echo "  策略已存在"
fi

echo ""
echo "=== 3. 核查/创建/修复 RAM role $ROLE_NAME ==="
if ! aliyun ram GetRole --RoleName "$ROLE_NAME" 2>/dev/null; then
  echo "  角色不存在, 创建..."
  DOC=$(cat "$SCRIPT_DIR/github-actions-trust-policy.json" | tr -d '\n')
  aliyun ram CreateRole \
    --RoleName "$ROLE_NAME" \
    --AssumeRolePolicyDocument "$DOC" \
    --Description "GitHub Actions deploy role for daifuyang/* repos"
else
  echo "  角色已存在, force UpdateRole trust policy (兼容 GitHub 新 OIDC sub 格式)..."
  DOC=$(cat "$SCRIPT_DIR/github-actions-trust-policy.json" | tr -d '\n')
  aliyun ram UpdateRole \
    --RoleName "$ROLE_NAME" \
    --NewAssumeRolePolicyDocument "$DOC"
fi

echo ""
echo "=== 4. 附加权限策略到 role ==="
ATTACHED=$(aliyun ram ListPoliciesForRole --RoleName "$ROLE_NAME" \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print(','.join(p['PolicyName'] for p in d.get('Policies',{}).get('Policy',[])))")
if echo "$ATTACHED" | grep -q "$POLICY_NAME"; then
  echo "  $POLICY_NAME 已挂在 role, 跳过"
else
  aliyun ram AttachPolicyToRole \
    --PolicyName "$POLICY_NAME" \
    --PolicyType Custom \
    --RoleName "$ROLE_NAME"
fi

echo ""
echo "=== 5. 验证最终状态 ==="
echo "--- Role ARN ---"
ROLE_ARN=$(aliyun ram GetRole --RoleName "$ROLE_NAME" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['Role']['Arn'])")
echo "  $ROLE_ARN"

echo "--- Trust policy (oidc:sub) ---"
aliyun ram GetRole --RoleName "$ROLE_NAME" \
  | python3 -c "
import sys, json, re
doc = json.load(sys.stdin)['Role']['AssumeRolePolicyDocument']
m = re.search(r'\"oidc:sub\":\s*\[([^\]]+)\]', doc)
print('  ' + (m.group(1) if m else 'NOT FOUND'))
"

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
echo "  (或 per-repo: gh secret set FC_DEPLOY_ROLE_ARN --repo daifuyang/<repo> --body \"$ROLE_ARN\")"