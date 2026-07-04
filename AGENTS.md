# AGENTS.md

## Repository Scope

This repository owns reusable GitHub Actions workflows and shared CI/CD building
blocks for DenDenMushi service repositories.

Primary responsibilities:

- Reusable Go CI workflows.
- Reusable Node and Python CI workflows.
- Reusable Docker image build and push workflows.
- Reusable GitOps image-promotion workflows.
- Shared ECR publishing conventions.
- Common workflow documentation and examples.

Do not hardcode assumptions that only apply to one service unless the workflow
input makes that behavior explicit.

## Current Direction

Service repositories should:

- Run Go, Node, or Python checks through reusable CI as appropriate.
- Build Docker images from their local Dockerfiles.
- Push immutable image tags to ECR, usually `github.sha`.
- Open or update GitOps promotion PRs against the `kubernetes` repository when
  a deployable image should roll out.

The `kubernetes` repository decides which image tags run in EKS. GitOps
promotion updates Kubernetes manifests; service repositories and shared image
workflows must not deploy directly to the cluster.

## Workflow Rules

- Prefer `workflow_call` reusable workflows for shared behavior.
- Keep required inputs small and obvious.
- Use GitHub OIDC for AWS auth; do not add static AWS credentials.
- Do not deploy to EKS from shared image workflows.
- Expose useful outputs such as image URI and digest.
- Prefer immutable tags for release paths; `latest` or branch tags may be extra
  convenience tags only.
- Keep workflows service-agnostic.
- Keep AI-agent services on the same CI bar as other services: tests, type or
  vet checks, lint/format checks, SAST, SCA, and artifact retention where the
  language workflow supports them.
- Do not print secrets, tokens, model prompts containing sensitive data, or
  command outputs into GitHub Actions logs.

## Validation

Before completing workflow changes, parse YAML where possible:

```bash
ruby -e 'require "yaml"; ARGV.each { |f| YAML.load_file(f); puts "ok #{f}" }' .github/workflows/*.yaml
```

If adding shell-heavy steps, keep scripts POSIX/bash clear and fail fast with
default GitHub Actions behavior. Avoid embedding secrets in logs.
