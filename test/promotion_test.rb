# frozen_string_literal: true

require "minitest/autorun"
require "yaml"
require "open3"
require "tmpdir"

class PromotionTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  DIGEST = "sha256:" + "a" * 64

  def promote(yaml, digest: DIGEST, tag: "source-commit", require_digest: false)
    workflow = YAML.load_file(File.join(ROOT, ".github/workflows/promote-kubernetes-image.yaml"))
    step = workflow.fetch("jobs").fetch("promote").fetch("steps").find { |s| s["name"] == "Update Kustomize image reference" }
    Dir.mktmpdir do |dir|
      path = File.join(dir, "kustomization.yaml")
      File.write(path, yaml)
      out, err, status = Open3.capture3({ "IMAGE_NAME" => "example/service", "IMAGE_TAG" => tag,
        "IMAGE_DIGEST" => digest, "REQUIRE_DIGEST" => require_digest.to_s, "KUSTOMIZATION_PATH" => path }, "bash", "-e", "-c", step.fetch("run"))
      [status.success?, File.read(path), out + err]
    end
  end

  def fixture(reference = "newTag: old")
    "apiVersion: kustomize.config.k8s.io/v1beta1\nkind: Kustomization\nimages:\n  - name: example/service\n    newName: registry/service\n    #{reference}\n  - name: example/untouched\n    newTag: keep\n\nresources:\n  - base\n"
  end

  def test_tag_migrates_to_digest_and_other_content_is_preserved
    passed, result, log = promote(fixture)
    assert passed, log
    assert_includes result, "digest: #{DIGEST}"
    refute_includes result, "newTag: old"
    assert_includes result, "  - name: example/untouched\n    newTag: keep\n\nresources:"
  end

  def test_digest_update_is_idempotent
    original = fixture("digest: #{DIGEST}")
    passed, result, log = promote(original)
    assert passed, log
    assert_equal original, result
  end

  def test_legacy_tag_is_supported_only_before_digest_migration
    assert promote(fixture, digest: "").first
    refute promote(fixture("digest: #{DIGEST}"), digest: "").first
  end

  def test_migrated_caller_cannot_fall_back_to_a_tag
    refute promote(fixture, digest: "", require_digest: true).first
    assert promote(fixture, require_digest: true).first
  end

  def test_invalid_or_ambiguous_inputs_fail_without_modifying_file
    ["sha256:abc", "sha256:" + "G" * 64, "latest"].each do |digest|
      passed, result, = promote(fixture, digest: digest)
      refute passed
      assert_equal fixture, result
    end
    refute promote(fixture.gsub("example/untouched", "example/service")).first
    refute promote(fixture, tag: "bad;tag").first
  end
end
