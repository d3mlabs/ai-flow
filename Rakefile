# frozen_string_literal: true

require "rake/testtask"

# Mirrors d3mlabs/dev: test_loader runs first (-r) so ASTTransform.install and
# the load path are set before any test.
Rake::TestTask.new(:test) do |t|
  t.libs << "test"
  t.libs << File.expand_path("lib", __dir__)
  t.ruby_opts << "-r #{File.expand_path('test/test_loader.rb', __dir__)}"
  t.test_files = FileList["test/**/*_test.rb"]
  t.warning = false
end

task default: :test
