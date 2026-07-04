# GitHub Actions Shared

Reusable CI/CD workflows for DenDenMushi service repositories.

The workflows intentionally stop at test/build, image publishing, and GitOps
promotion PRs. EKS rollout is handled by Kubernetes manifests and Argo CD, not
by service repositories directly applying manifests to the cluster.

## Validation

Run the workflow tests before committing shared workflow changes:

```bash
ruby test/workflows_test.rb
```

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
      test-command: npm test -- --runInBand --coverage
      build-command: npm run build
```

The workflow uses `npm ci`, npm dependency caching, optional non-mutating lint,
tests, a production build, a Semgrep SAST scan, and a production-dependency
`npm audit` SCA scan.
It uploads best-effort test/coverage artifacts from `coverage/**`, generates a
coverage table in the GitHub Actions job summary when `coverage/lcov.info`
exists, and uploads `coverage-summary.md` with the test artifacts. Semgrep SARIF
and npm audit JSON reports are retained as separate artifacts for 14 days.
SAST and SCA are enabled by default. A repository can disable one temporarily,
override the commands, or point artifact inputs at custom report paths.

For Angular CLI projects, use an Angular coverage command:

```yaml
jobs:
  ci:
    uses: NUS-MTech-Capstone/github-actions-shared/.github/workflows/node-ci.yaml@main
    with:
      node-version: "22"
      run-lint: true
      test-command: npm test -- --watch=false --code-coverage
      build-command: npm run build
```

Security and artifact overrides:

```yaml
jobs:
  ci:
    uses: NUS-MTech-Capstone/github-actions-shared/.github/workflows/node-ci.yaml@main
    with:
      run-sast: true
      sast-command: semgrep scan --config auto --sarif --output semgrep.sarif .
      sast-artifact-path: semgrep.sarif
      run-sca: true
      sca-command: npm audit --omit=dev --audit-level=high --json > npm-audit.json
      sca-artifact-path: npm-audit.json
      coverage-lcov-path: coverage/lcov.info
```

### Python CI

Create `.github/workflows/ci.yaml` in a Python service repository:

```yaml
name: CI

on:
  pull_request:
  push:
    branches: [main]

jobs:
  ci:
    uses: NUS-MTech-Capstone/github-actions-shared/.github/workflows/python-ci.yaml@main
    with:
      python-version: "3.12"
```

The Python workflow uses `uv sync --frozen`, Ruff lint and format checks, Mypy,
Pytest, a package build, Bandit SAST, and `pip-audit` SCA. Coverage, Bandit,
and `pip-audit` reports are uploaded as artifacts for 14 days. SAST, SCA,
coverage, lint, format, and type checks are enabled by default.

Temporary overrides:

```yaml
jobs:
  ci:
    uses: NUS-MTech-Capstone/github-actions-shared/.github/workflows/python-ci.yaml@main
    with:
      run-typecheck: true
      run-sast: true
      run-sca: true
```

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
      go-version: "1.26.4"
```

The Go workflow runs tests, `go vet`, a `gosec` SAST scan, and a
`govulncheck` SCA scan. Tests generate coverage by default. The coverage table
is written to the GitHub Actions job summary, and `coverage.out`,
`coverage.txt`, and a browsable `coverage.html` are uploaded in the
`go-coverage` artifact for 14 days. SAST and SCA reports are uploaded as
`go-sast-gosec` and `go-sca-govulncheck`.

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

Create `.github/workflows/image.yaml` in a service repository. Keep this
separate from `.github/workflows/ci.yaml`: CI proves the commit, while the image
workflow publishes an immutable build artifact only after CI has passed.

```yaml
name: Image

on:
  workflow_run:
    workflows: ["CI"]
    types: [completed]
    branches: [main]

jobs:
  image:
    if: ${{ github.event.workflow_run.conclusion == 'success' }}
    uses: NUS-MTech-Capstone/github-actions-shared/.github/workflows/docker-build-push-ecr.yaml@main
    with:
      aws-region: ap-southeast-1
      ecr-repository: dendenmushi/session-manager
      source-ref: ${{ github.event.workflow_run.head_sha }}
      image-tag: ${{ github.event.workflow_run.head_sha }}
      extra-tags: main
    secrets:
      AWS_ROLE_ARN: ${{ secrets.AWS_ROLE_ARN }}
```

Use the commit SHA tag in Kubernetes manifests for deterministic releases. The
GitOps promotion workflow updates the image tag in the `kubernetes` repository
after this workflow pushes to ECR.

Name the service workflow `cd.yaml` only when it also promotes or deploys the
image. For this project, prefer:

- `ci.yaml`: tests, build, coverage, SAST, and SCA.
- `image.yaml`: build and push the immutable image to ECR.
- `promote.yaml`: open or update the GitOps PR that changes the Kubernetes
  image tag.

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
