# frozen_string_literal: true
require 'minitest/autorun'
require 'yaml'
require 'json'
require 'tmpdir'
require 'open3'
require 'fileutils'

class TerraformCiTest < Minitest::Test
  def workflow
    YAML.load_file(File.expand_path('../.github/workflows/terraform-ci.yaml', __dir__))
  end

  def runner
    step = workflow.fetch('jobs').fetch('plan').fetch('steps').find { |s| s['name'] == 'Run refreshed read-only plan' }
    step.fetch('run').lines[1...-1].join
  end

  def run_fixture(mode = 'clean', overrides = {})
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, 'runner.py'), runner)
      fake = File.join(dir, 'terraform')
      File.write(fake, <<~'PY')
        #!/usr/bin/env python3
        import json, os, pathlib, signal, sys, time
        args = sys.argv[1:]
        with open('calls.jsonl', 'a') as f: f.write(json.dumps(args) + '\n')
        mode = os.environ.get('FIXTURE_MODE', 'clean')
        if args[0] == 'init':
            sys.exit(1 if mode == 'init_error' else 0)
        for arg in args:
            if arg.startswith('-var-file='):
                p = pathlib.Path(arg.split('=', 1)[1])
                assert p.stat().st_mode & 0o777 == 0o600
        if mode == 'interrupt':
            os.kill(os.getppid(), signal.SIGTERM)
            time.sleep(30)
        if mode == 'malformed':
            print('not-json')
        elif mode != 'missing_summary':
            print(json.dumps({'type':'change_summary','changes':{'add':1 if mode == 'changes' else 0,'change':0,'remove':0}}))
        if mode in ('error', 'secret_error'):
            print(json.dumps({'type':'diagnostic','diagnostic':{'severity':'error','summary':'Access denied secret-fixture-value','detail':'NEVER-PUBLISH-DETAIL','snippet':{'code':'NEVER-PUBLISH-SOURCE'}}}))
            sys.exit(1)
        sys.exit(2 if mode == 'changes' else 0)
      PY
      File.chmod(0o755, fake)
      env = {'PATH' => "#{dir}:#{ENV.fetch('PATH')}", 'FIXTURE_MODE' => mode,
             'AWS_ROLE_ARN' => 'arn:aws:iam::123456789012:role/test-plan',
             'TFVARS_JSON_SECRET' => '{"password":"secret-fixture-value"}',
             'REQUIRED_VARIABLE_FILES' => 'ci.secret.auto.tfvars.json',
             'TFVARS_JSON_INPUT' => '', 'TFVARS_HCL' => '', 'TEAMMATE_TFVARS_HCL' => '',
             'TERRAFORM_INIT_ARGS' => '-input=false -lockfile=readonly', 'TERRAFORM_PLAN_ARGS' => '-input=false -no-color',
             'GITHUB_STEP_SUMMARY' => File.join(dir, 'summary.md')}.merge(overrides)
      stdout, stderr, status = Open3.capture3(env, 'python3', 'runner.py', chdir: dir)
      report = JSON.parse(File.read(File.join(dir, '.terraform-ci/plan.json')))
      calls_path = File.join(dir, 'calls.jsonl')
      calls = File.exist?(calls_path) ? File.readlines(calls_path).map { |line| JSON.parse(line) } : []
      calls.flatten.grep(/^-var-file=/).each do |arg|
        refute File.exist?(arg.split('=', 2)[1]), 'temporary variables survived completion'
      end
      refute_includes stdout + stderr + JSON.generate(report), 'secret-fixture-value'
      refute_includes stdout + stderr + JSON.generate(report), 'NEVER-PUBLISH'
      yield status, report, calls
    end
  end

  def test_clean_and_changed_plans_pass_without_apply
    %w[clean changes].each do |mode|
      run_fixture(mode) do |status, report, calls|
        assert status.success?
        assert_equal 'passed', report['status']
        assert_equal mode == 'changes' ? 2 : 0, report['plan_exit_code']
        assert_equal %w[init plan], calls.map(&:first)
        assert_includes calls.last, '-lock=false'
        refute calls.flatten.any? { |arg| arg.start_with?('-out', '-refresh=false') }
      end
    end
  end

  def test_errors_malformed_missing_output_and_interruption_fail_with_retained_result
    %w[init_error error secret_error malformed missing_summary interrupt].each do |mode|
      run_fixture(mode) do |status, report, _calls|
        refute status.success?, mode
        assert_equal 'failed', report['status'], mode
      end
    end
  end

  def test_missing_role_or_required_file_and_invalid_json_fail_before_terraform
    [{'AWS_ROLE_ARN' => ''}, {'TFVARS_JSON_SECRET' => ''}, {'TFVARS_JSON_SECRET' => '{invalid'}, {'TFVARS_JSON_SECRET' => '[]'}].each do |override|
      run_fixture('clean', override) do |status, report, calls|
        refute status.success?
        assert_equal 'inputs', report['stage']
        assert_empty calls
      end
    end
  end

  def test_both_existing_hcl_files_are_required_and_cleaned
    run_fixture('clean', 'TFVARS_HCL' => 'password = "secret-fixture-value"', 'TEAMMATE_TFVARS_HCL' => 'users = ["fixture"]',
                'REQUIRED_VARIABLE_FILES' => 'secrets.tfvars teammate-access.local.tfvars') do |status, _report, calls|
      assert status.success?
      assert_equal 3, calls.last.grep(/^-var-file=/).size
    end
  end

  def test_bypass_arguments_are_rejected
    %w[-refresh=false -target=aws_instance.example -destroy -out=plan.bin -var=secret=value -lock=true].each do |arg|
      run_fixture('clean', 'TERRAFORM_PLAN_ARGS' => arg) do |status, _report, calls|
        refute status.success?
        assert_empty calls
      end
    end
  end

  def test_validation_never_gets_credentials_or_backend_access
    job = workflow.fetch('jobs').fetch('validate')
    text = JSON.generate(job)
    refute_includes text, 'secrets.'
    refute_includes text, 'configure-aws-credentials'
    assert_includes text, '-backend=false'
    assert_includes text, '-lockfile=readonly'
    assert_equal ['contents'], workflow.fetch('permissions').keys
    plan = workflow.fetch('jobs').fetch('plan')
    assert_includes plan['if'], 'inputs.run-plan'
    assert_includes plan['if'], 'head.repo.full_name == github.repository'
    assert_equal 'validate', plan['needs']
    assert_equal false, plan.fetch('concurrency').fetch('cancel-in-progress')
    refute_match(/terraform apply|terraform destroy/, JSON.generate(workflow))
    uploads = plan['steps'].select { |s| s['uses'].to_s.start_with?('actions/upload-artifact') }
    assert_equal 1, uploads.size
    assert_equal '${{ always() }}', uploads.first['if']
    assert_equal '${{ inputs.working-directory }}/.terraform-ci/plan.json', uploads.first['with']['path']
  end
end
