# GitHub Actions Shared

Reusable CI/CD workflows for DenDenMushi service repositories.

The workflows intentionally stop at test/build and image publishing. EKS rollout
should be handled later by Kubernetes manifests and ArgoCD, not by service
repositories directly applying manifests to the cluster.

## Usage

### Go CI

Create `.github/workflows/ci.yaml` in a service repository:

```yaml
name: CI

on:
  pull_request:
  push:
    branches: [main]

jobs:
  ci:
    uses: NUS-MTech-Capstone/github-actions-shared/.github/workflows/go-ci.yaml@main
    with:
      go-version: "1.26.3"
```

### Build and Push Image to ECR

Create `.github/workflows/image.yaml` in a service repository:

```yaml
name: Image

on:
  push:
    branches: [main]

jobs:
  image:
    uses: NUS-MTech-Capstone/github-actions-shared/.github/workflows/docker-build-push-ecr.yaml@main
    with:
      aws-region: ap-southeast-1
      ecr-repository: dendenmushi/session-manager
      image-tag: ${{ github.sha }}
      extra-tags: main
    secrets:
      AWS_ROLE_ARN: ${{ secrets.AWS_ROLE_ARN }}
```

Use the commit SHA tag in Kubernetes manifests for deterministic releases. Later,
ArgoCD Image Updater or a separate GitOps promotion workflow can update the
image tag in the `kubernetes` repository after this workflow pushes to ECR.
