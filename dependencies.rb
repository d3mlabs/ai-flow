# frozen_string_literal: true

# Toolchain-only manifest for dev: it provisions this exact Ruby
# (rbenv + shadowenv) for `dev` commands. Gems stay bundler-managed
# through the hand-written Gemfile.
require "dev/deps"

Dev::Deps.define do
  ruby "3.3.10"
end
