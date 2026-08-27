# frozen_string_literal: true

require "minitest/autorun"
require "yaml"

class WorkflowsTest < Minitest::Test
  WORKFLOW_DIR = File.expand_path("../.github/workflows", __dir__)

  def test_all_workflows_parse_as_yaml
    workflow_paths.each do |path|
      assert_kind_of Hash, YAML.load_file(path), "#{path} should parse as YAML"
    end
  end

  def test_node_ci_exposes_security_scan_inputs
    inputs = workflow_call_inputs(node_ci)

    assert_equal true, inputs.fetch("run-sast").fetch("default")
    assert_equal "semgrep scan --config auto --sarif --output semgrep.sarif .",
                 inputs.fetch("sast-command").fetch("default")
    assert_equal "semgrep.sarif", inputs.fetch("sast-artifact-path").fetch("default")
    assert_equal true, inputs.fetch("run-sca").fetch("default")
    assert_equal "npm audit --omit=dev --audit-level=high --json > npm-audit.json",
                 inputs.fetch("sca-command").fetch("default")
    assert_equal "npm-audit.json", inputs.fetch("sca-artifact-path").fetch("default")
    assert_equal "coverage/**", inputs.fetch("test-artifact-paths").fetch("default")
    assert_equal "coverage/lcov.info", inputs.fetch("coverage-lcov-path").fetch("default")
  end

  def test_node_ci_runs_semgrep_in_dedicated_job
    job = node_ci.fetch("jobs").fetch("sast")

    assert_equal "${{ inputs.run-sast }}", job.fetch("if")
    assert_equal "semgrep/semgrep", job.fetch("container").fetch("image")
    assert_includes step_names(job), "Run Semgrep"
    assert_equal "${{ inputs.sast-command }}", step_by_name(job, "Run Semgrep").fetch("run")
    assert_equal true, step_by_name(job, "Run Semgrep").fetch("continue-on-error")
    assert_artifact_upload job, "Upload Semgrep report", "node-sast-semgrep", "${{ inputs.working-directory }}/${{ inputs.sast-artifact-path }}"
    assert_refail_step job, "Fail on Semgrep findings", "${{ steps.semgrep.outcome == 'failure' }}"
  end

  def test_node_ci_runs_npm_audit_in_dedicated_job
    job = node_ci.fetch("jobs").fetch("sca")

    assert_equal "${{ inputs.run-sca }}", job.fetch("if")
    assert_includes step_names(job), "Set up Node.js"
    assert_includes step_names(job), "Install dependencies"
    assert_equal "${{ inputs.sca-command }}", step_by_name(job, "Run npm audit").fetch("run")
    assert_equal true, step_by_name(job, "Run npm audit").fetch("continue-on-error")
    assert_artifact_upload job, "Upload npm audit report", "node-sca-npm-audit", "${{ inputs.working-directory }}/${{ inputs.sca-artifact-path }}"
    assert_refail_step job, "Fail on npm audit findings", "${{ steps.npm-audit.outcome == 'failure' }}"
  end

  def test_node_ci_runs_lint_in_dedicated_job
    lint_job = node_ci.fetch("jobs").fetch("lint")
    test_job = node_ci.fetch("jobs").fetch("test")

    assert_equal "Lint", lint_job.fetch("name")
    assert_equal "${{ inputs.run-lint }}", lint_job.fetch("if")
    assert_includes step_by_name(lint_job, "Lint").fetch("run"), "tee lint.log"
    assert_artifact_upload lint_job, "Upload lint artifacts", "node-lint-artifacts", "${{ inputs.working-directory }}/lint.log"
    assert_test_job_depends_on_lint test_job
    refute_includes step_names(test_job), "Lint"
  end

  def test_node_ci_uploads_test_artifacts
    job = node_ci.fetch("jobs").fetch("test")

    assert_includes step_names(job), "Generate coverage summary"
    assert_equal "${{ always() && inputs.coverage-lcov-path != '' }}",
                 step_by_name(job, "Generate coverage summary").fetch("if")
    assert_artifact_upload job, "Upload test artifacts", "node-test-artifacts", "${{ inputs.working-directory }}/${{ inputs.test-artifact-paths }}"
    assert_includes step_by_name(job, "Upload test artifacts").fetch("with").fetch("path"),
                    "${{ inputs.working-directory }}/coverage-summary.md"
    assert_equal "ignore", step_by_name(job, "Upload test artifacts").fetch("with").fetch("if-no-files-found")
  end

  def test_go_ci_exposes_security_artifact_inputs
    inputs = workflow_call_inputs(go_ci)

    assert_equal "1.26.5", inputs.fetch("go-version").fetch("default")
    assert_equal "gosec.sarif", inputs.fetch("gosec-artifact-path").fetch("default")
    assert_equal "govulncheck.json", inputs.fetch("govulncheck-artifact-path").fetch("default")
  end

  def test_terraform_ci_exposes_plan_only_inputs
    inputs = workflow_call_inputs(terraform_ci)

    assert_equal "1.14.5", inputs.fetch("terraform-version").fetch("default")
    assert_equal ".", inputs.fetch("working-directory").fetch("default")
    assert_equal "ap-southeast-1", inputs.fetch("aws-region").fetch("default")
    assert_equal "-input=false -lockfile=readonly", inputs.fetch("terraform-init-args").fetch("default")
    assert_equal "-input=false -no-color", inputs.fetch("terraform-plan-args").fetch("default")
    assert_equal true, inputs.fetch("run-plan").fetch("default")
    assert_equal "", inputs.fetch("tfvars-json").fetch("default")
  end

  def test_terraform_ci_uses_oidc_and_does_not_apply
    job = terraform_ci.fetch("jobs").fetch("terraform")

    assert_equal "write", terraform_ci.fetch("permissions").fetch("id-token")
    assert_includes step_names(job), "Configure AWS credentials"
    assert_equal "${{ secrets.AWS_ROLE_ARN }}",
                 step_by_name(job, "Configure AWS credentials").fetch("with").fetch("role-to-assume")
    assert_includes step_by_name(job, "Terraform init").fetch("run"), "terraform init"
    assert_includes step_by_name(job, "Terraform validate").fetch("run"), "terraform validate"
    assert_equal "${{ inputs.run-plan }}", step_by_name(job, "Terraform plan").fetch("if")
    assert_includes step_by_name(job, "Terraform plan").fetch("run"), "terraform plan"
    refute_includes step_names(job), "Terraform apply"
  end

  def test_docker_image_workflow_can_checkout_explicit_source_ref
    inputs = workflow_call_inputs(docker_image)
    checkout = step_by_name(docker_image.fetch("jobs").fetch("image"), "Checkout")

    assert_equal "", inputs.fetch("source-ref").fetch("default")
    assert_equal "${{ inputs.source-ref }}", checkout.fetch("with").fetch("ref")
  end

  def test_go_ci_uploads_coverage_and_scan_artifacts
    test_job = go_ci.fetch("jobs").fetch("test")
    sast_job = go_ci.fetch("jobs").fetch("sast")
    sca_job = go_ci.fetch("jobs").fetch("sca")

    assert_artifact_upload test_job, "Upload coverage reports", "go-coverage", nil, "${{ always() && inputs.run-coverage }}"
    assert_artifact_upload sast_job, "Upload gosec report", "go-sast-gosec", "${{ inputs.working-directory }}/${{ inputs.gosec-artifact-path }}"
    assert_artifact_upload sca_job, "Upload govulncheck report", "go-sca-govulncheck", "${{ inputs.working-directory }}/${{ inputs.govulncheck-artifact-path }}"
  end

  def test_go_ci_runs_lint_in_dedicated_job
    lint_job = go_ci.fetch("jobs").fetch("lint")
    test_job = go_ci.fetch("jobs").fetch("test")

    assert_equal "Lint", lint_job.fetch("name")
    assert_equal "${{ inputs.run-vet }}", lint_job.fetch("if")
    assert_includes step_by_name(lint_job, "Vet").fetch("run"), "go vet ./..."
    assert_includes step_by_name(lint_job, "Vet").fetch("run"), "tee go-vet.log"
    assert_artifact_upload lint_job, "Upload lint artifacts", "go-lint-artifacts", "${{ inputs.working-directory }}/go-vet.log"
    assert_test_job_depends_on_lint test_job
    refute_includes step_names(test_job), "Vet"
  end

  def test_go_ci_prints_gosec_text_output_while_writing_sarif
    run_command = step_by_name(go_ci.fetch("jobs").fetch("sast"), "Run gosec").fetch("run")

    assert_includes run_command, "-fmt sarif"
    assert_includes run_command, "-stdout"
    assert_includes run_command, "-verbose text"
  end

  def test_go_ci_refails_after_security_artifact_uploads
    sast_job = go_ci.fetch("jobs").fetch("sast")
    sca_job = go_ci.fetch("jobs").fetch("sca")

    assert_equal true, step_by_name(sast_job, "Run gosec").fetch("continue-on-error")
    assert_refail_step sast_job, "Fail on gosec findings", "${{ steps.gosec.outcome == 'failure' }}"
    assert_equal true, step_by_name(sca_job, "Run govulncheck").fetch("continue-on-error")
    assert_refail_step sca_job, "Fail on govulncheck findings", "${{ steps.govulncheck.outcome == 'failure' }}"
  end

  def test_python_ci_exposes_quality_gate_inputs
    inputs = workflow_call_inputs(python_ci)

    assert_equal "3.12", inputs.fetch("python-version").fetch("default")
    assert_equal true, inputs.fetch("run-lint").fetch("default")
    assert_equal true, inputs.fetch("run-format-check").fetch("default")
    assert_equal true, inputs.fetch("run-typecheck").fetch("default")
    assert_equal true, inputs.fetch("run-coverage").fetch("default")
    assert_equal true, inputs.fetch("run-sast").fetch("default")
    assert_equal true, inputs.fetch("run-sca").fetch("default")
    assert_equal "bandit.json", inputs.fetch("bandit-artifact-path").fetch("default")
    assert_equal "pip-audit.json", inputs.fetch("pip-audit-artifact-path").fetch("default")
  end

  def test_python_ci_runs_expected_checks
    lint_job = python_ci.fetch("jobs").fetch("lint")
    test_job = python_ci.fetch("jobs").fetch("test")

    assert_equal "Lint", lint_job.fetch("name")
    assert_equal "${{ inputs.run-lint || inputs.run-format-check || inputs.run-typecheck }}", lint_job.fetch("if")
    assert_includes step_names(lint_job), "Install dependencies"
    assert_equal "uv sync --frozen", step_by_name(lint_job, "Install dependencies").fetch("run")
    assert_includes step_by_name(lint_job, "Ruff check").fetch("run"), "uv run ruff check ."
    assert_includes step_by_name(lint_job, "Ruff check").fetch("run"), "tee ruff-check.log"
    assert_includes step_by_name(lint_job, "Ruff format check").fetch("run"), "uv run ruff format --check ."
    assert_includes step_by_name(lint_job, "Ruff format check").fetch("run"), "tee ruff-format-check.log"
    assert_includes step_by_name(lint_job, "Mypy").fetch("run"), "uv run mypy"
    assert_includes step_by_name(lint_job, "Mypy").fetch("run"), "tee mypy.log"
    assert_artifact_upload lint_job, "Upload lint artifacts", "python-lint-artifacts", "${{ inputs.working-directory }}/ruff-check.log"

    assert_test_job_depends_on_lint test_job
    assert_includes step_names(test_job), "Install dependencies"
    assert_equal "uv sync --frozen", step_by_name(test_job, "Install dependencies").fetch("run")
    assert_includes step_by_name(test_job, "Pytest").fetch("run"), "uv run pytest --cov=incident_agent"
    assert_equal "uv build --no-build-isolation", step_by_name(test_job, "Build package").fetch("run")
    assert_artifact_upload test_job, "Upload coverage reports", "python-coverage", "${{ inputs.working-directory }}/coverage.xml", "${{ always() && inputs.run-coverage }}"
  end

  def test_python_ci_uploads_security_artifacts_and_refails
    sast_job = python_ci.fetch("jobs").fetch("sast")
    sca_job = python_ci.fetch("jobs").fetch("sca")

    assert_equal "${{ inputs.run-sast }}", sast_job.fetch("if")
    assert_equal "${{ inputs.run-sca }}", sca_job.fetch("if")
    assert_equal true, step_by_name(sast_job, "Run Bandit").fetch("continue-on-error")
    assert_equal true, step_by_name(sca_job, "Run pip-audit").fetch("continue-on-error")
    assert_artifact_upload sast_job, "Upload Bandit report", "python-sast-bandit", "${{ inputs.working-directory }}/${{ inputs.bandit-artifact-path }}"
    assert_artifact_upload sca_job, "Upload pip-audit report", "python-sca-pip-audit", "${{ inputs.working-directory }}/${{ inputs.pip-audit-artifact-path }}"
    assert_refail_step sast_job, "Fail on Bandit findings", "${{ steps.bandit.outcome == 'failure' }}"
    assert_refail_step sca_job, "Fail on pip-audit findings", "${{ steps.pip-audit.outcome == 'failure' }}"
  end

  private

  def workflow_paths
    Dir[File.join(WORKFLOW_DIR, "*.yaml")].sort
  end

  def node_ci
    @node_ci ||= YAML.load_file(File.join(WORKFLOW_DIR, "node-ci.yaml"))
  end

  def go_ci
    @go_ci ||= YAML.load_file(File.join(WORKFLOW_DIR, "go-ci.yaml"))
  end

  def python_ci
    @python_ci ||= YAML.load_file(File.join(WORKFLOW_DIR, "python-ci.yaml"))
  end

  def terraform_ci
    @terraform_ci ||= YAML.load_file(File.join(WORKFLOW_DIR, "terraform-ci.yaml"))
  end

  def docker_image
    @docker_image ||= YAML.load_file(File.join(WORKFLOW_DIR, "docker-build-push-ecr.yaml"))
  end

  def workflow_call_inputs(workflow)
    # Psych follows YAML 1.1 and parses the GitHub Actions "on" key as boolean true.
    on = workflow["on"] || workflow[true]
    on.fetch("workflow_call").fetch("inputs")
  end

  def step_names(job)
    job.fetch("steps").map { |step| step.fetch("name") }
  end

  def step_by_name(job, name)
    job.fetch("steps").find { |step| step["name"] == name } || flunk("missing step #{name}")
  end

  def assert_artifact_upload(job, step_name, artifact_name, artifact_path, condition = "${{ always() }}")
    step = step_by_name(job, step_name)

    assert_equal condition, step.fetch("if")
    assert_match(/\Aactions\/upload-artifact@v(?:[4-9]|\d{2,})\z/, step.fetch("uses"))
    assert_equal artifact_name, step.fetch("with").fetch("name")
    assert_includes step.fetch("with").fetch("path"), artifact_path if artifact_path
    assert_equal 14, step.fetch("with").fetch("retention-days")
  end

  def assert_test_job_depends_on_lint(job)
    assert_equal "Test", job.fetch("name")
    assert_equal "lint", job.fetch("needs")
    assert_equal "${{ always() && needs.lint.result != 'failure' && needs.lint.result != 'cancelled' }}",
                 job.fetch("if")
  end

  def assert_refail_step(job, step_name, condition)
    step = step_by_name(job, step_name)

    assert_equal condition, step.fetch("if")
    assert_equal "exit 1", step.fetch("run")
  end
end
