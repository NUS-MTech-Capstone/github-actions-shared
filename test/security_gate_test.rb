# frozen_string_literal: true

require "minitest/autorun"
require "yaml"
require "json"
require "open3"
require "tmpdir"

class SecurityGateTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)

  def run_gate(stack, report, scanner_status: 0)
    workflow = YAML.load_file(File.join(ROOT, ".github/workflows/#{stack}-ci.yaml"))
    job, name = stack == "go" ? ["sca", "Run govulncheck"] : ["sast", "Run Semgrep"]
    command = workflow.fetch("jobs").fetch(job).fetch("steps").find { |s| s["name"] == name }.fetch("run")
    Dir.mktmpdir do |dir|
      fixture = File.join(dir, "fixture")
      output = File.join(dir, "report")
      File.write(fixture, report)
      scanner = File.join(dir, "govulncheck")
      File.write(scanner, "#!/bin/sh\ncat \"$FIXTURE\"\nexit \"$SCANNER_STATUS\"\n")
      File.chmod(0o755, scanner)
      env = {
        "PATH" => "#{dir}:#{ENV.fetch('PATH')}", "FIXTURE" => fixture,
        "REPORT_PATH" => output, "SCANNER_STATUS" => scanner_status.to_s,
        "SAST_COMMAND" => 'cat "$FIXTURE" > "$REPORT_PATH"; exit "$SCANNER_STATUS"'
      }
      stdout, stderr, status = Open3.capture3(env, "bash", "-e", "-o", "pipefail", "-c", command)
      return [status.success?, stdout + stderr, File.exist?(output) ? File.read(output) : nil]
    end
  end

  def go_report(function: nil)
    messages = [{ config: { protocol_version: "v1.0.0", scan_level: "symbol" } }]
    if function
      messages << { finding: { osv: "GO-FIXTURE-0001", trace: [{ module: "fixture", function: function }] } }
    end
    messages.map { |m| JSON.generate(m) }.join("\n")
  end

  def semgrep_report(results = [])
    JSON.generate(version: "2.1.0", runs: [{ invocations: [{ executionSuccessful: true }], results: results }])
  end

  def test_clean_go_report_passes
    assert run_gate("go", go_report).first
  end

  def test_reachable_go_finding_fails_even_when_scanner_exits_zero
    report = go_report(function: "Vulnerable")
    passed, log, artifact = run_gate("go", report)
    refute passed
    assert_includes log, "GO-FIXTURE-0001"
    assert_equal report, artifact
  end

  def test_go_package_only_finding_is_not_a_symbol_finding
    assert run_gate("go", go_report(function: "")).first
  end

  def test_missing_malformed_and_wrong_level_go_reports_fail
    ["", "{}", go_report + "{", '{"config":{"scan_level":"package"}}',
     go_report + '\n{"finding":{"osv":"GO-FIXTURE","trace":[]}}'].each do |report|
      refute run_gate("go", report).first, report.inspect
    end
  end

  def test_clean_semgrep_report_passes
    assert run_gate("node", semgrep_report).first
  end

  def test_semgrep_override_cannot_succeed_with_findings
    report = semgrep_report([{ ruleId: "fixture.security.rule", message: { text: "Fixture" } }])
    passed, log, artifact = run_gate("node", report)
    refute passed
    assert_includes log, "unsuppressed findings"
    assert_equal report, artifact
  end

  def test_missing_or_invalid_semgrep_report_fails
    ["", "{}", semgrep_report + "{", '{"version":"2.1.0","runs":[{"results":null}]}'].each do |report|
      refute run_gate("node", report).first
    end
  end

  def test_scanner_errors_fail_and_preserve_artifacts
    { "go" => go_report, "node" => semgrep_report }.each do |stack, report|
      passed, _, artifact = run_gate(stack, report, scanner_status: 2)
      refute passed
      assert_equal report, artifact
    end
  end
end
