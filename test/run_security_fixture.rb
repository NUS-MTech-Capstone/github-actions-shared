# frozen_string_literal: true

# Execute the exact reusable-workflow gate with an isolated scanner fixture.
# A negative case deliberately returns a nonzero status to GitHub Actions.
require "yaml"
require "json"
require "fileutils"
require "open3"

stack, scenario = ARGV
abort "expected go|node and clean|finding|malformed|scanner-error" unless
  %w[go node].include?(stack) && %w[clean finding malformed scanner-error].include?(scenario)
root = File.expand_path("..", __dir__)
directory = File.join(root, "fixture-output", stack)
FileUtils.mkdir_p(directory)
report = if stack == "go"
           lines = [{ config: { protocol_version: "v1.0.0", scan_level: "symbol" } }]
           lines << { finding: { osv: "GO-FIXTURE-0001", trace: [{ function: "Vulnerable" }] } } if scenario == "finding"
           lines.map { |line| JSON.generate(line) }.join("\n")
         else
           results = scenario == "finding" ? [{ ruleId: "fixture.security.rule" }] : []
           JSON.generate(version: "2.1.0", runs: [{ invocations: [{ executionSuccessful: true }], results: results }])
         end
report = "malformed{" if scenario == "malformed"
fixture = File.join(directory, "scanner-fixture.json")
File.write(fixture, report)
scanner = File.join(directory, "govulncheck")
File.write(scanner, "#!/bin/sh\ncat \"$FIXTURE\"\nexit \"$SCANNER_STATUS\"\n")
File.chmod(0o755, scanner)
workflow = YAML.load_file(File.join(root, ".github/workflows/#{stack}-ci.yaml"))
job, step = stack == "go" ? ["sca", "Run govulncheck"] : ["sast", "Run Semgrep"]
command = workflow.fetch("jobs").fetch(job).fetch("steps").find { |entry| entry["name"] == step }.fetch("run")
environment = {
  "PATH" => "#{directory}:#{ENV.fetch('PATH')}", "FIXTURE" => fixture,
  "REPORT_PATH" => File.join(directory, "scan-report.json"),
  "SCANNER_STATUS" => scenario == "scanner-error" ? "2" : "0",
  "SAST_COMMAND" => 'cat "$FIXTURE" > "$REPORT_PATH"; exit "$SCANNER_STATUS"'
}
stdout, stderr, status = Open3.capture3(environment, "bash", "-e", "-o", "pipefail", "-c", command)
File.write(File.join(directory, "gate.log"), stdout + stderr)
File.write(File.join(directory, "outcome.json"), JSON.pretty_generate(stack: stack, scenario: scenario, exit_status: status.exitstatus))
puts stdout + stderr
exit status.exitstatus
