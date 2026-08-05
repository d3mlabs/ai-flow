# typed: false — rspock Where tables are load-time rewritten and have no static typing.
# frozen_string_literal: true

require "test_helper"
require "support/fakes"

transform!(RSpock::AST::Transformation)
class AiFlow::ProvenanceTest < Minitest::Test
  REPO = "d3mlabs/demo"

  # A permission API that always errors — the fail-closed path. Subclasses
  # the real class so sorbet-runtime's sig checks accept it at the seam.
  class ErroringGitHub < FakeGitHub
    def collaborator_permission(owner_repo, login)
      raise AiFlow::GitHub::Error, "HTTP 500"
    end
  end

  def build_provenance(github)
    AiFlow::Provenance.new(github: github, owner_repo: REPO)
  end

  test "write and admin are trusted; read and none are not" do
    Given "an author holding the permission"
    github = FakeGitHub.new
    github.seed_permission("someone", permission)

    Expect
    build_provenance(github).trusted?("someone") == trusted

    Where
    permission | trusted
    "admin"    | true
    "write"    | true
    "read"     | false
    "none"     | false
  end

  test "a ghost author is untrusted without an API call" do
    Given "a deleted user surfacing as the empty login"
    github = FakeGitHub.new

    Expect "fail closed, and no permission probe for a login that cannot hold one"
    build_provenance(github).trusted?("") == false
    github.calls.empty?

    Cleanup
    nil
  end

  test "the verdict is memoized — one permission probe per login" do
    Given "a sweep asking about the same two authors repeatedly"
    github = FakeGitHub.new
    github.seed_permission("member", "write")
    provenance = build_provenance(github)

    When "asking four times across two logins"
    provenance.trusted?("member")
    provenance.trusted?("driveby")
    provenance.trusted?("member")
    provenance.trusted?("driveby")

    Then "each login hit the API exactly once, negative verdicts included"
    github.calls == [
      [:collaborator_permission, REPO, "member"],
      [:collaborator_permission, REPO, "driveby"],
    ]

    Cleanup
    nil
  end

  test "a failed permission lookup fails closed" do
    Given "a permission API that errors"
    github = ErroringGitHub.new

    Expect
    build_provenance(github).trusted?("someone") == false

    Cleanup
    nil
  end
end
