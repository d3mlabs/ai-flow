# typed: true

# The RSpock test dialect is rewritten at load time by ast_transform:
# `transform!` is a source marker the transformation strips, `test`
# becomes a def, and the block labels become assertion sections. None of
# that surface exists for Sorbet's static pass, so this shim declares
# the pre-transform source's methods. Runtime behavior is untouched —
# these definitions are never loaded.

class Object
  sig { params(transformation: T.untyped).void }
  def transform!(transformation); end
end

class Minitest::Test
  sig { params(name: String, block: T.proc.bind(T.attached_class).void).void }
  def self.test(name, &block); end

  sig { params(description: T.nilable(String)).void }
  def Given(description = nil); end

  sig { params(description: T.nilable(String)).void }
  def When(description = nil); end

  sig { params(description: T.nilable(String)).void }
  def Then(description = nil); end

  sig { params(description: T.nilable(String)).void }
  def Expect(description = nil); end

  sig { params(description: T.nilable(String)).void }
  def Cleanup(description = nil); end

  sig { params(exception_class: T.class_of(Exception)).void }
  def raises(exception_class); end
end
