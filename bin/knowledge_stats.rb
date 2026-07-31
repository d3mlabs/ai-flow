#!/usr/bin/env ruby
# frozen_string_literal: true

# Mines a knowledge repo checkout for the deployment statistics reported in
# docs/paper.md (Deployment Status section): corpus composition, index size
# (the always-on context tax), git history, and PR lifecycle via `gh`.
#
# Usage: bin/knowledge_stats.rb [checkout_path]
#
# The checkout path defaults to the current directory. PR lifecycle stats
# require `gh` authenticated against the repo's remote; they are skipped
# (with a note) when unavailable.

require "date"
require "json"
require "open3"
require "time"

# @param command [Array<String>] argv-style command
# @param chdir [String] working directory
# @return [String, nil] stdout on success, nil on failure
def capture(command, chdir:)
  stdout, _stderr, status = Open3.capture3(*command, chdir: chdir)
  status.success? ? stdout : nil
end

# @param index_path [String] path to index.md
# @return [Hash] tier and section composition of the index
def index_stats(index_path)
  lines = File.readlines(index_path)
  sections = {}
  tier = nil
  current = nil
  lines.each do |line|
    case line
    when /^## Invariants/ then tier = current = "invariants"
    when /^## Knowledge/ then tier = "knowledge"
    when /^### (\S+)/ then current = Regexp.last_match(1) if tier == "knowledge"
    when /^- \[/ then sections[current] = sections.fetch(current, 0) + 1
    end
  end
  words = File.read(index_path).split.size
  { lines: lines.size, words: words, sections: sections }
end

# @param repo_path [String] knowledge repo checkout
# @return [Hash] skill counts and word volume
def skills_stats(repo_path)
  paths = Dir.glob(File.join(repo_path, "skills", "*", "SKILL.md"))
  words = paths.sum { |path| File.read(path).split.size }
  { count: paths.size, words: words }
end

# @param repo_path [String] knowledge repo checkout
# @return [Hash] repo age and merge counts from git history
def history_stats(repo_path)
  first = capture(%w[git log --reverse --format=%ad --date=short], chdir: repo_path)&.lines&.first&.strip
  merges = capture(%w[git log --merges --oneline], chdir: repo_path)&.lines&.size || 0
  commits = capture(%w[git rev-list --count HEAD], chdir: repo_path)&.strip
  age_days = first ? (Date.today - Date.parse(first)).to_i : nil
  { first_commit: first, age_days: age_days, commits: commits, merge_commits: merges }
end

# @param repo_path [String] knowledge repo checkout
# @return [Hash, nil] PR lifecycle stats from gh, nil when gh is unavailable
def pr_stats(repo_path)
  fields = "number,state,isDraft,createdAt,mergedAt"
  raw = capture(["gh", "pr", "list", "--state", "all", "--limit", "500", "--json", fields], chdir: repo_path)
  return nil unless raw

  prs = JSON.parse(raw)
  merged = prs.select { |pr| pr["state"] == "MERGED" }
  hours_to_merge = merged.filter_map do |pr|
    next unless pr["mergedAt"]

    ((Time.parse(pr["mergedAt"]) - Time.parse(pr["createdAt"])) / 3600).round(1)
  end
  {
    total: prs.size,
    merged: merged.size,
    closed_unmerged: prs.count { |pr| pr["state"] == "CLOSED" },
    open_drafts: prs.count { |pr| pr["state"] == "OPEN" && pr["isDraft"] },
    median_hours_to_merge: hours_to_merge.sort[hours_to_merge.size / 2],
  }
end

repo_path = File.expand_path(ARGV.fetch(0, "."))
abort "no index.md under #{repo_path} — not a knowledge repo checkout" unless File.exist?(File.join(repo_path, "index.md"))

index = index_stats(File.join(repo_path, "index.md"))
skills = skills_stats(repo_path)
history = history_stats(repo_path)
prs = pr_stats(repo_path)

invariants = index[:sections].delete("invariants") || 0
knowledge = index[:sections].values.sum

puts "corpus:"
puts "  learnings: #{invariants + knowledge} (#{invariants} invariants, #{knowledge} knowledge)"
puts "  sections: #{index[:sections].map { |name, count| "#{name}=#{count}" }.join(', ')}"
puts "  skills: #{skills[:count]} files, #{skills[:words]} words"
puts "  index (always-on tax): #{index[:lines]} lines, #{index[:words]} words"
puts "history:"
puts "  first commit: #{history[:first_commit]} (#{history[:age_days]} days ago)"
puts "  commits: #{history[:commits]}, merge commits: #{history[:merge_commits]}"
if prs
  puts "pr lifecycle:"
  puts "  total: #{prs[:total]}, merged: #{prs[:merged]}, closed unmerged: #{prs[:closed_unmerged]}, open drafts: #{prs[:open_drafts]}"
  puts "  median hours to merge: #{prs[:median_hours_to_merge]}"
else
  puts "pr lifecycle: skipped (gh unavailable or unauthenticated)"
end
