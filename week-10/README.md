# Week 10: Why OIDC Is Safer Than Storing AWS Keys in GitHub Secrets

A stored AWS access key is a long-lived credential. If it leaks through a workflow log, a compromised third-party action, or a copied repo, it keeps working until someone notices and rotates it. With OIDC there is no stored secret at all. Each workflow run gets a signed token from GitHub, and AWS exchanges it for temporary credentials that expire on their own (one hour by default). A leaked token is useless after the run ends.

OIDC is also more tightly scoped. The role's trust policy checks the token's `aud` claim (must be `sts.amazonaws.com`) and its `sub` claim, which names the repo and branch. In this project only pushes to `main` on this repo can assume `github-actions-deploy-role`. A static key has no such check, because anyone holding the key can use it from anywhere. Without a condition on the trust policy, any GitHub repo could assume the role, so that condition is the real security boundary. Newer repos use an immutable `sub` format with numeric owner and repo IDs, so a recycled repo name can't match an old trust policy.

Finally, OIDC is easier to audit and maintain. Each run uses a session name like `gha-<run id>`, so CloudTrail shows which run did what, instead of one shared key attributed to a user. There is also no key to rotate, store, or accidentally commit.

## What this project uses

- IAM OIDC provider for `token.actions.githubusercontent.com`
- Role `github-actions-deploy-role`, trusted only for this repo's `main` branch
- Workflow at `.github/workflows/deploy.yml`: build image, push to ECR, redeploy ECS
- No AWS access keys stored anywhere in GitHub
