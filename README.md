# GitHub Actions Shared

Reusable CI/CD workflows for DenDenMushi service repositories.

The workflows intentionally stop at test/build and image publishing. EKS rollout
should be handled later by Kubernetes manifests and ArgoCD, not by service
repositories directly applying manifests to the cluster.

## Usage

### Node CI

Create `.github/workflows/ci.yaml` in a Node service repository:

```yaml
jobs:
  ci:
    uses: NUS-MTech-Capstone/github-actions-shared/.github/workflows/node-ci.yaml@main
    with:
      node-version: "22"
      run-lint: true
      test-command: npm test -- --runInBand
      build-command: npm run build
```

The workflow uses `npm ci`, npm dependency caching, optional non-mutating lint,
tests, and a production build.

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

The Go workflow runs tests, `go vet`, a `gosec` SAST scan, and a
`govulncheck` SCA scan. Tests generate coverage by default. The coverage table
is written to the GitHub Actions job summary, and `coverage.out`,
`coverage.txt`, and a browsable `coverage.html` are uploaded in the
`go-coverage` artifact for 14 days.

Coverage and both scans are enabled by default. A repository can disable one
temporarily or pin a different `gosec` release:

```yaml
jobs:
  ci:
    uses: NUS-MTech-Capstone/github-actions-shared/.github/workflows/go-ci.yaml@main
    with:
      run-coverage: true
      run-sast: false
      run-sca: true
      gosec-version: "v2.27.1"
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

### Promote Image to Kubernetes GitOps

After an image has been pushed, service repositories can open a promotion PR in
the Kubernetes GitOps repository:

```yaml
jobs:
  promote:
    if: github.event_name == 'push' && github.ref == 'refs/heads/main'
    uses: NUS-MTech-Capstone/github-actions-shared/.github/workflows/promote-kubernetes-image.yaml@main
    with:
      service-name: session-manager
      image-name: 000000000000.dkr.ecr.ap-southeast-1.amazonaws.com/dendenmushi/session-manager
      image-tag: ${{ github.sha }}
    secrets:
      GITOPS_TOKEN: ${{ secrets.GITOPS_TOKEN }}
```

`GITOPS_TOKEN` should be a fine-scoped GitHub App token or equivalent credential
that can push a branch and open a pull request in `NUS-MTech-Capstone/kubernetes`.
The workflow updates exactly one image entry, renders the dev overlay with
`kubectl kustomize`, and opens or updates a PR. Argo CD deploys after that PR is
merged to the branch it tracks.
