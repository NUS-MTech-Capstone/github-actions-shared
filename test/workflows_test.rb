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
    assert_equal "semgrep scan --config auto .", inputs.fetch("sast-command").fetch("default")
    assert_equal true, inputs.fetch("run-sca").fetch("default")
    assert_equal "npm audit --audit-level=high", inputs.fetch("sca-command").fetch("default")
  end

  def test_node_ci_runs_semgrep_in_dedicated_job
    job = node_ci.fetch("jobs").fetch("sast")

    assert_equal "${{ inputs.run-sast }}", job.fetch("if")
    assert_equal "semgrep/semgrep", job.fetch("container").fetch("image")
    assert_includes step_names(job), "Run Semgrep"
    assert_equal "${{ inputs.sast-command }}", step_by_name(job, "Run Semgrep").fetch("run")
  end

  def test_node_ci_runs_npm_audit_in_dedicated_job
    job = node_ci.fetch("jobs").fetch("sca")

    assert_equal "${{ inputs.run-sca }}", job.fetch("if")
    assert_includes step_names(job), "Set up Node.js"
    assert_includes step_names(job), "Install dependencies"
    assert_equal "${{ inputs.sca-command }}", step_by_name(job, "Run npm audit").fetch("run")
  end

  private

  def workflow_paths
    Dir[File.join(WORKFLOW_DIR, "*.yaml")].sort
  end

  def node_ci
    @node_ci ||= YAML.load_file(File.join(WORKFLOW_DIR, "node-ci.yaml"))
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
end
