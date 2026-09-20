# daifuyang/.github

> **daifuyang org-level shared GitHub infrastructure for deploying TanStack-Start apps to Alibaba Cloud FC3.**

This meta-repo (`daifuyang/.github`) provides reusable GitHub Actions
workflows and a composite action that any repo under the `daifuyang`
GitHub org can call to deploy to FC3 with **zero per-repo console setup**.

## What lives here

```
.github/
├── actions/
│   └── fc-deploy-env/      # composite action: OIDC → STS → ~/.s/access.yaml
└── workflows/
    └── deploy-fc3.yml      # reusable workflow: build → stage → s deploy → smoke

bin/
├── bootstrap-domain.sh     # 1 命令引导新域名 (cert + CAS + DNS)
└── phase1-run.sh           # 1 次性账号资源创建 (IdP / role / policy)
```

## Architecture (the 30-second version)

```
┌─ GitHub: daifuyang/* repo ──────────────────────────────────────────────┐
│ .github/workflows/deploy.yml  (5 lines)                                │
│   uses: daifuyang/.github/.github/workflows/deploy-fc3.yml@main         │
└──────────────┬──────────────────────────────────────────────────────────┘
               ↓
┌─ GitHub Actions runner (ubuntu-latest) ──────────────────────────────────┐
│ 1. OIDC token (audience=github-actions)                                 │
│ 2. AssumeRoleWithOIDC → GithubActionsFcDeployer (shared role)        │
│ 3. Write STS triplet to ~/.s/access.yaml                               │
│ 4. pnpm build → node scripts/build-fc.mjs → deploy/fc/code/             │
│ 5. s -y (Serverless Devs reads s.yaml, deploys to FC3)                  │
└──────────────┬──────────────────────────────────────────────────────────┘
               ↓
┌─ Alibaba Cloud ────────────────────────────────────────────────────────┐
│ FC3 (custom.debian12 + node-22) → fc3-domain → DNS CNAME → user        │
└────────────────────────────────────────────────────────────────────────┘
```

## Trust model

- **Single OIDC IdP** `github-actions` (per aliyun account, created once)
- **Single ClientId** `github-actions` (not per-repo)
- **Single RAM role** `GithubActionsFcDeployer` with owner-scoped trust:
  `repo:daifuyang/*` (legacy subjects) and `repo:daifuyang@*/*`
  (subjects containing immutable owner/repository IDs).
- **Deployment triggers belong to each repository**: the shared role allows
  all branches (including `main` and `all`), tags, and environments under
  `daifuyang`. Each repository configures its workflow triggers and any
  environment protection rules; the shared workflow does not filter branches.
- **Single permission policy** `GithubActionsFcPerm` (`fc:*` + `vpc:Describe*`)
- **All daifuyang repos share the same deploy capability** but with
  per-function isolation through naming (`<repo>-*` function names)

## Org-level GitHub Secret (set once)

| Secret | Value |
|---|---|
| `FC_DEPLOY_ROLE_ARN` | `acs:ram::1650595695532785:role/GithubActionsFcDeployer` |

All repos under `daifuyang/*` inherit this and can deploy immediately.

## Add a new repo

1. Copy `.github/workflows/deploy.yml` (5 lines) into the new repo
2. Copy `deploy/fc/s.yaml` (placeholder template) and `deploy/fc/server/{bootstrap,server.mjs}` + `scripts/build-fc.mjs`
3. Edit 3 fields in s.yaml placeholders (`<FUNCTION_NAME>`, `<CUSTOM_DOMAIN>`, `<CERT_NAME>`) — actually the workflow auto-substitutes them
4. Run `bootstrap-domain.sh <new-app>.zerocmf.com zerocmf.com`
5. `git push origin main`

**That's it.** No RAM console work, no GitHub Secret work.

## Add a new domain

```bash
./bin/bootstrap-domain.sh <subdomain>.<rootdomain> <rootdomain>
# e.g.
./bin/bootstrap-domain.sh new-app.zerocmf.com zerocmf.com
```

What it does:
1. `acme.sh --issue --dns dns_ali -d <domain>` (Let's Encrypt cert)
2. `aic aliyun-cert:upload` (push cert to Alibaba CAS)
3. `aic dns:add <root> <sub> CNAME <account>.cn-shanghai.fc.aliyuncs.com`

## One-time setup (run once per aliyun account)

Already done for the `daifuyang` aliyun account (account 1650595695532785):

- [x] OIDC IdP `github-actions`
- [x] Permission policy `GithubActionsFcPerm`
- [x] RAM role `GithubActionsFcDeployer` (org-wide trust)
- [x] Org-level secret `FC_DEPLOY_ROLE_ARN`

If you need to redo this in a new aliyun account:

```bash
./bin/phase1-run.sh
```

It is idempotent (checks for existing resources before creating).

The trust policy source is `bin/github-actions-trust-policy.json`. Committing
this file does not apply it to Alibaba Cloud. To update only the existing
shared role, run the following with an authorized Alibaba Cloud CLI profile
from this repository in Bash, then verify the returned policy:

```bash
aliyun ram UpdateRole \
  --RoleName GithubActionsFcDeployer \
  --NewAssumeRolePolicyDocument "$(cat bin/github-actions-trust-policy.json)"
aliyun ram GetRole --RoleName GithubActionsFcDeployer
```

The shared workflow reference `@main` selects the version of this repository;
it does not require the calling repository to deploy from `main`.

## References

- DocBase SOP: [tanstack-start-2](https://docbase.zerocmf.com/documents/tanstack-start-2) (FC3 deployment reference)
- Reference implementations:
  - [daifuyang/dock](https://github.com/daifuyang/dock) — minimal TanStack-Start + FC3 (this org's reference)
  - [daifuyang/yishan-tan](https://github.com/daifuyang/yishan-tan) — DB-backed TanStack-Start starter
  - [daifuyang/yishan-mp](https://github.com/daifuyang/yishan-mp) — full-featured production app
