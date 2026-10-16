# GitHub Actions Shared

Reusable CI/CD workflows for DenDenMushi service repositories.

The workflows intentionally stop at test/build, image publishing, and GitOps
promotion PRs. EKS rollout is handled by Kubernetes manifests and Argo CD, not
by service repositories directly applying manifests to the cluster.

## Validation

Run the workflow tests before committing shared workflow changes:

```bash
ruby -Itest -e 'Dir["test/*_test.rb"].sort.each { |file| require File.expand_path(file) }'
```

## CI Steps

| CI Step | Description |
| --- | --- |
| Checkout source | Checks out the service repository, or a requested source ref for image builds. |
| Set up language runtime | Installs the configured Node.js, Python, or Go version and enables dependency caching where supported. |
| Install dependencies | Restores project dependencies with the language-specific lockfile workflow, such as `npm ci`, `uv sync --frozen`, or `go mod download`. |
| Lint and format checks | Runs optional or default non-mutating lint and format checks in a dedicated Lint job, such as npm lint, Ruff check, Ruff format check, or `go vet`. |
| Type checks | Runs language type checks where supported, currently Mypy for Python services in the Lint job. |
| Upload lint artifacts | Retains best-effort lint and type-check logs for 14 days. |
| Test and coverage | Runs the configured test command, optionally with race detection or coverage, and writes coverage summaries to the GitHub Actions job summary. |
| Upload test artifacts | Retains coverage and test outputs as best-effort artifacts for 14 days. |
| Build application | Builds the service package or server binary after checks pass. |
| SAST scan | Runs static application security testing with Semgrep, Bandit, or gosec and uploads reports before failing on findings. |
| SCA scan | Runs dependency vulnerability analysis with npm audit, pip-audit, or govulncheck and uploads reports before failing on findings. |
| Terraform plan | Runs Terraform fmt, init, validate, and plan through GitHub OIDC without apply. |
| Build and push image | Builds the Docker image with Buildx, tags it with a source commit tag and exposes its content digest, and optionally pushes it to ECR through GitHub OIDC. |
| Promote GitOps image | Updates the Kubernetes GitOps image digest, renders the target Kustomize overlay, and opens or updates the promotion PR. |

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

The workflow uses `npm ci`, npm dependency caching, optional non-mutating lint
in a dedicated `Lint` job, tests in a `Test` job, a production build, a Semgrep
SAST scan, and a production-dependency `npm audit` SCA scan.
It uploads best-effort test/coverage artifacts from `coverage/**`, generates a
coverage table in the GitHub Actions job summary when `coverage/lcov.info`
exists, and uploads `coverage-summary.md` with the test artifacts. When lint is
enabled, `lint.log` is retained as the `node-lint-artifacts` artifact. Semgrep
SARIF and npm audit JSON reports are retained as separate artifacts for 14 days.
SAST and SCA are enabled by default. Custom commands and report paths retain
the shared finding and report-validation gates.

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
      sast-command: semgrep scan --error --config auto --sarif --output semgrep.sarif .
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

The Python workflow uses `uv sync --frozen`, Ruff lint and format checks plus
Mypy in a dedicated `Lint` job, Pytest and package build in a `Test` job,
Bandit SAST, and `pip-audit` SCA. Coverage, lint/type-check logs, Bandit, and
`pip-audit` reports are uploaded as artifacts for 14 days. SAST, SCA, coverage,
lint, format, and type checks are enabled by default.

Explicit check settings:

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
      go-version: "1.26.9"
```

The Go workflow runs `go vet` in a dedicated `Lint` job, tests in a `Test` job,
a `gosec` SAST scan, and a `govulncheck` SCA scan. Tests generate coverage by
default. The coverage table is written to the GitHub Actions job summary, and
`coverage.out`, `coverage.txt`, and a browsable `coverage.html` are uploaded in
the `go-coverage` artifact for 14 days. The `go vet` log is uploaded as
`go-lint-artifacts`. SAST and SCA reports are uploaded as `go-sast-gosec` and
`go-sca-govulncheck`.

Coverage and both scans are enabled by default. Explicit settings can also pin
the `gosec` release:

```yaml
jobs:
  ci:
    uses: NUS-MTech-Capstone/github-actions-shared/.github/workflows/go-ci.yaml@main
    with:
      run-coverage: true
      run-sast: true
      run-sca: true
      gosec-version: "v2.27.1"
```

### Terraform CI

The reusable Terraform workflow always checks formatting, initializes locked
providers/modules with `-backend=false`, and validates configuration without AWS
credentials. Terraform 1.14.5 is the default. Validation artifacts are retained
for 14 days, including on failure.

With `run-plan: true` (the default), a separate dependent job assumes the supplied
read-only AWS role through OIDC and runs a full refreshed plan against the
checked-in backend. Fork PRs never receive this job. Callers must restrict push
and manual-dispatch branches to those allowed by their role trust policy.
No workflow performs apply or destroy. Plans use `-lock=false` because the role
cannot mutate state; operators must avoid concurrent infrastructure applies.

```yaml
jobs:
  terraform:
    permissions:
      contents: read
      id-token: write
    uses: NUS-MTech-Capstone/github-actions-shared/.github/workflows/terraform-ci.yaml@<reviewed-commit-sha>
    with:
      terraform-version: "1.14.5"
      required-variable-files: secrets.tfvars teammate-access.local.tfvars
    secrets:
      AWS_ROLE_ARN: ${{ secrets.AWS_TERRAFORM_PLAN_ROLE_ARN }}
      TFVARS_HCL: ${{ secrets.TERRAFORM_TFVARS_HCL }}
      TEAMMATE_TFVARS_HCL: ${{ secrets.TERRAFORM_TEAMMATE_TFVARS_HCL }}
```

`tfvars-json` and secret `TFVARS_JSON` remain supported. Input JSON is applied
before secret JSON, then `secrets.tfvars`, then `teammate-access.local.tfvars`.
`required-variable-files` names the supplied files that must exist; missing
inputs or malformed JSON fail the plan. Variable files have mode 0600 and are
removed with raw execution output on success, failure and handled interruption.

Plan exit codes 0 (no changes) and 2 (changes proposed) pass; errors, malformed
output and missing summaries fail. The artifact and job summary contain only
source identity, stage/exit status, change counts and sanitized diagnostic
summaries. They never contain state, variable contents, saved apply plans,
resource values or raw provider diagnostics.

Use `run-plan: false` explicitly for retired environments or validation-only
callers; this needs no AWS role and reports that live planning was not performed.

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

Use the build output digest in Kubernetes manifests for deterministic releases. Commit SHA tags are traceability labels, not an immutability guarantee. The
GitOps promotion workflow updates the image digest in the `kubernetes` repository
after this workflow pushes to ECR.

Do not add direct `push`, tag, or `workflow_dispatch` triggers to an image
workflow. Those paths bypass the successful CI-run requirement. To retry a
transient image publishing failure, rerun the `CI` workflow for the same
`main` commit; the completed successful rerun will publish that exact SHA again.

Name the service workflow `cd.yaml` only when it also promotes or deploys the
image. For this project, prefer:

- `ci.yaml`: tests, build, coverage, SAST, and SCA.
- `image.yaml`: build and push the immutable image to ECR.
- `promote.yaml`: open or update the GitOps PR that changes the Kubernetes
  image digest.

### Promote Image to Kubernetes GitOps

After an image has been pushed, service repositories can open a promotion PR in
the Kubernetes GitOps repository:

```yaml
jobs:
  promote:
    needs: image
    uses: NUS-MTech-Capstone/github-actions-shared/.github/workflows/promote-kubernetes-image.yaml@main
    with:
      service-name: session-manager
      image-name: 000000000000.dkr.ecr.ap-southeast-1.amazonaws.com/dendenmushi/session-manager
      image-tag: ${{ github.event.workflow_run.head_sha }}
      image-digest: ${{ needs.image.outputs.image-digest }}
      require-digest: true
    secrets:
      GITOPS_TOKEN: ${{ secrets.GITOPS_TOKEN }}
```

`GITOPS_TOKEN` should be a fine-scoped GitHub App token or equivalent credential
that can push a branch and open a pull request in `NUS-MTech-Capstone/kubernetes`.
The promotion job depends on the successful image job and uses the same tested
SHA from the triggering CI run. The workflow updates exactly one image entry,
renders the dev overlay with `kubectl kustomize`, and opens or updates a PR.
Argo CD deploys after that PR is merged to the branch it tracks.

## Enforced scan and API contracts

Go CI pins govulncheck v1.9.0 and scans at symbol level. The JSON report is
retained and explicitly checked: reachable findings, scanner errors, unsupported
report format, and empty/malformed reports fail the job. Package/module-only
findings are retained for review but are not classified as reachable findings.
Go CI defaults to Go 1.26.9; caller toolchains and Docker builders must agree.

Node CI enables Semgrep `--error` and independently checks its SARIF results,
including when a caller overrides the command. Scanner failures or missing/
malformed reports fail even when no finding was emitted. Artifacts upload before
the job propagates failure.

Specification-owning services call `openapi-ci.yaml` alongside their language CI.
It validates OpenAPI 3.0/3.1 with `openapi-spec-validator==0.9.0` and retains the
specification and validation result for 90 days. Service handler tests verify
representative wire responses against the checked-in schemas.

## Digest promotion

`promote-kubernetes-image.yaml` accepts `image-digest` from
`needs.image.outputs.image-digest`. It validates the SHA-256 digest, replaces the
matching Kustomize `newTag` with `digest`, preserves unrelated image entries,
and renders the overlay before opening a PR. `image-tag` remains the source
label in the PR. Legacy tag-only callers remain compatible until their image is
pinned; an already digest-pinned image cannot be downgraded by a legacy caller.
All DenDenMushi deployment callers must pass the digest. Runtime verification
must compare the deployed digest with the built OCI index or its platform
manifest. Convenience aliases such as `main` are never deployment identities.

Image revision labels use the checked-out source SHA, not the workflow trigger
SHA. Publication remains conditional on successful source CI; promotion depends
on the successful image job. Shared behavioural tests exercise rejected/clean
scanner results, scanner failures, malformed reports, digest migration,
idempotence, and downgrade rejection.

Project service callers set `require-digest: true`; the tag fallback remains
available only for callers that have not migrated. A missing build digest then
fails promotion even when the existing overlay still uses a tag.

## Controlled security-gate acceptance

The manually dispatched `Security gate acceptance fixtures` workflow executes
the production Go and Semgrep gate commands with isolated scanner outputs.
Run `clean`, `finding`, `malformed`, and `scanner-error` scenarios. Negative
scenarios deliberately fail, retain their reports and exit statuses for 90 days,
and skip the dependent release-eligibility job. This fixture workflow cannot
publish images or access deployment credentials. Ordinary CI separately runs
the behavioural test suite, including malformed/missing reports and overrides.
