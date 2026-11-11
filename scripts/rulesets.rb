#!/usr/bin/env ruby
# frozen_string_literal: true

# Fails when a ruleset requires a status context no workflow job can report, and reports the mirror
# of that mistake: a ruleset nobody enforces gates nothing, and a context no ruleset requires is
# dead weight.
#
# It checks the other half of the same gate too: a workflow a pull request starts, with no Actions
# event policy that allows `pull_request_target` for it. GitHub's default policy blocks that event in
# public repositories from 2026-12-02, and a blocked entry workflow reports no contexts at all - the
# required ones then look provided and never appear, which is the silent failure this file exists
# for. The event rule is an allowlist, so the same policy can also stop the push or schedule
# trigger of the workflow it lets a pull request start; that is a warning rather than a failure.
# A required context with no provider is silent in both directions. It looks like a real gate in the
# API, so nothing suggests checking it, and once enforcement is on it blocks every pull request; a
# ruleset that is `disabled` blocks nothing and looks the same as one that does. `Version
# development` on kirjorjos/Minecheck sat disabled for a month requiring a context the matrix had
# stopped reporting, and nothing noticed either half.
#
# Check names come from jobs, never from workflows: a job's `name:`, else its id, is what GitHub
# reports. A job that calls a reusable workflow reports `<caller> / <callee job>` for each job in
# the callee, where `<caller>` is that `name:` or id again, so the call tree is walked here rather
# than guessed. A `${{ matrix.* }}` in a name is a pattern, because the matrix expands it into one
# check per leg.
#
# A reusable workflow in another repository is followed through the API when there is one. When it
# cannot be read, a required context that would live under that caller is reported as unverified
# instead of missing: the difference between "no provider" and "provider not visible from here" is
# the difference between a defect and a guess.
#
# Usage:
#   ruby scripts/rulesets.rb                                    # every consumer, through the API
#   ruby scripts/rulesets.rb --repo kirjorjos/Minecheck
#   ruby scripts/rulesets.rb --workflows .github/workflows --rulesets /tmp/rulesets.json \
#                            --policies /tmp/policies.json
#
# The offline form reads one tree and the exported ruleset and policy lists, which is how the
# matching rules are exercised without creating a ruleset to break. Without `--policies` it says the
# policies were not read instead of reporting every entry workflow as unprotected.
#
# Reading another repository's rulesets needs `administration: read` on the app, and its Actions
# policies need `administration: write` - that endpoint has no read-only permission - so the workflow
# that runs this asks for write.

require "json"
require "open3"
require "yaml"

# `${{ matrix.loader }}` and friends: one check per expansion, so the name is matched as a pattern.
MATRIX = /\$\{\{[^}]*\}\}/
# A reusable workflow can call another; a cycle or a runaway chain is a defect, not a depth to follow.
MAX_DEPTH = 5
# `owner/repo/.github/workflows/file.yml@ref` - a reusable workflow outside this repository.
EXTERNAL = %r{\A(?<repo>[\w.-]+/[\w.-]+)/(?<path>\.github/workflows/[\w./-]+\.ya?ml)@(?<ref>.+)\z}
# The check types gated to `pull_request_target`: `type-rules.yml` runs on it and nothing else,
# because commenting on and closing a fork's pull request needs the base repository's token. A
# consumer whose registry lists none of these starts no such run it needs, so a blocked event there
# costs nothing and is not reported.
PULL_REQUEST_TARGET_TYPES = %w[rules].freeze

class Failure < StandardError; end

def gh(*args)
  out, err, status = Open3.capture3("gh", *args)
  raise Failure, "gh #{args.join(' ')} failed: #{err.strip}" unless status.success?

  out
end

def api_json(path) = JSON.parse(gh("api", path))

def gh_raw(path) = gh("api", "-H", "Accept: application/vnd.github.raw", path)

# The workflows under `.github/workflows/` at a ref, keyed by repository path.
def repo_workflows(repo, ref)
  tree = api_json("repos/#{repo}/git/trees/#{ref}?recursive=1")
  paths = tree.fetch("tree", []).map { |e| e["path"].to_s }
              .select { |p| p.start_with?(".github/workflows/") && p.match?(/\.ya?ml\z/) }
  paths.to_h { |p| [p, gh_raw("repos/#{repo}/contents/#{p}?ref=#{ref}")] }
end

# The same, from a checkout. Keys carry the `.github/workflows/` prefix so a `uses: ./...` path
# resolves the same way it does in `repo_workflows`.
#
# `root` is empty when the directory named is exactly `.github/workflows` - the documented
# `--workflows .github/workflows` - and `File.join("", key)` is `/key`, an absolute path that cannot
# exist. So the two are joined only when there is a root to join them with.
def dir_workflows(dir)
  root = dir.sub(%r{/?\.github/workflows/?\z}, "").chomp("/")
  keys = Dir.glob(File.join(dir, "**", "*.{yml,yaml}")).map { |p| p.delete_prefix("#{root}/") }
  keys.to_h { |key| [key, File.read([root, key].reject(&:empty?).join("/"))] }
end

# Fetches a reusable workflow from another repository, or nil when it cannot be read.
def external_fetcher
  lambda do |uses|
    match = EXTERNAL.match(uses)
    return nil unless match

    gh_raw("repos/#{match[:repo]}/contents/#{match[:path]}?ref=#{match[:ref]}")
  rescue Failure
    nil
  end
end

def jobs_in(source)
  doc = YAML.safe_load(source, aliases: true)
  jobs = doc.is_a?(Hash) ? doc["jobs"] : nil
  jobs.is_a?(Hash) ? jobs : {}
rescue Psych::Exception
  {}
end

# The events a workflow declares in `on:`. Psych reads a bare `on` key as the string, and a YAML 1.1
# parser would read it as `true`, so both spellings are looked for.
def triggers_in(source)
  doc = YAML.safe_load(source, aliases: true)
  declared = doc.is_a?(Hash) ? (doc["on"] || doc[true]) : nil
  case declared
  when String then [declared]
  when Array then declared.map(&:to_s)
  when Hash then declared.keys.map(&:to_s)
  else []
  end
rescue Psych::Exception
  []
end

# A policy applies to a workflow when it names no path condition - every workflow - or its include
# patterns match and nothing excludes it.
def policy_applies?(policy, path)
  condition = policy.dig("conditions", "workflow_path")
  return true if condition.nil?
  return false if condition["exclude"].to_a.any? { |pattern| path_pattern?(pattern, path) }

  included = condition["include"].to_a
  included.empty? || included.any? { |pattern| path_pattern?(pattern, path) }
end

# GitHub's globs for these conditions: `*` stays inside one path segment, `**` crosses them, and
# `~ALL` is every workflow.
def path_pattern?(pattern, path)
  pattern == "~ALL" || File.fnmatch?(pattern, path, File::FNM_PATHNAME | File::FNM_EXTGLOB)
end

# The events a policy permits, or nil when it restricts none: a policy without an event rule is an
# actor rule alone. An event rule's list is an allowlist for the workflows the policy applies to.
def allowed_events(policy)
  rule = policy.fetch("rules", []).find { |candidate| candidate["type"] == "restrict_action_events" }
  return nil if rule.nil?

  rule.dig("parameters", "allowed_events").to_a
end

def allows?(policy, event)
  events = allowed_events(policy)
  events.nil? || events.include?(event)
end

# Fails when a workflow a pull request starts has no active event policy that allows
# `pull_request_target` for it: from 2026-12-02 GitHub's default policy blocks that event in public
# repositories, and a blocked entry workflow reports none of the contexts its pull request waits on.
def audit_policies(repo, workflows, policies, types, problems, warnings, summary)
  if policies.nil?
    summary << "#{repo}: Actions policies were not read, so no entry workflow was checked"
    return
  end

  entries = workflows.select { |_path, source| triggers_in(source).include?("pull_request_target") }
                     .keys.sort
  if entries.empty?
    summary << "#{repo}: no workflow triggers on pull_request_target, so no event policy is needed"
    return
  end
  unless types.nil? || types.any? { |type| PULL_REQUEST_TARGET_TYPES.include?(type) }
    summary << "#{repo}: no check type is gated to pull_request_target, so the #{entries.size} " \
               "workflow(s) that trigger on it gate nothing"
    return
  end

  entries.each do |path|
    applicable = policies.select do |policy|
      policy["enforcement"] == "active" && policy_applies?(policy, path)
    end
    allowing = applicable.select { |policy| allows?(policy, "pull_request_target") }
    if allowing.empty?
      problems << "#{repo}: no active Actions event policy allows `pull_request_target` for " \
                  "`#{path}`, so from 2026-12-02 the default policy blocks it and no pull request " \
                  "gets the contexts it waits for"
      next
    end

    blocked = triggers_in(workflows[path]).reject do |event|
      allowing.any? { |policy| allows?(policy, event) }
    end
    next if blocked.empty?

    warnings << "#{repo}: `#{path}` also triggers on events its event policy does not allow " \
                "(#{blocked.sort.join(', ')}), so those runs would stop"
  end

  # Said even when every workflow passes: a step summary that never mentions policies reads the same
  # as one where nothing was looked at.
  summary << "#{repo}: event policies checked against #{entries.size} workflow(s) that trigger on " \
             "pull_request_target"
end

# Every check name a workflow tree can report, with reusable workflows followed. `unresolved` holds
# the callers whose callee jobs could not be read, so a required context under one of them is
# unverified rather than a failure.
def contexts_in(workflows, unresolved, fetcher)
  workflows.values
           .flat_map { |src| contexts_of(jobs_in(src), workflows, nil, 0, unresolved, fetcher) }
           .uniq
end

def contexts_of(jobs, workflows, prefix, depth, unresolved, fetcher)
  jobs.flat_map do |id, job|
    next [] unless job.is_a?(Hash)

    label = job["name"].to_s.strip
    label = id.to_s if label.empty?
    label = "#{prefix} / #{label}" if prefix

    uses = job["uses"].to_s
    next [label] if uses.empty?

    source = workflows[uses.delete_prefix("./")] || fetcher&.call(uses.delete_prefix("./"))
    if source.nil?
      # Say which caller could not be read; a cycle or a chain past MAX_DEPTH is one too.
      unresolved << label
      next []
    end
    if depth >= MAX_DEPTH
      unresolved << label
      next []
    end

    contexts_of(jobs_in(source), workflows, label, depth + 1, unresolved, fetcher)
  end
end

# `${{ ... }}` matches whatever the matrix expanded it to; everything else is literal. The split
# keeps its trailing empty field, because a name that ends in a matrix expression - `Lifecycle /
# ${{ matrix.loader }}` - is exactly the one whose wildcard has to reach the end of the context.
def matches?(pattern, context)
  parts = pattern.split(MATRIX, -1).map { |part| Regexp.escape(part) }
  Regexp.new("\\A#{parts.join('.*')}\\z").match?(context)
end

def under?(context, caller) = context.start_with?("#{caller} / ")

def required_contexts(ruleset)
  ruleset.fetch("rules", []).select { |r| r["type"] == "required_status_checks" }
         .flat_map { |r| r.dig("parameters", "required_status_checks") || [] }
         .filter_map { |c| c["context"] }
end

def ruleset_label(ruleset)
  name = ruleset["name"].to_s
  branches = ruleset.dig("conditions", "ref_name", "include") || []
  scope = branches.empty? ? "all branches" : branches.join(", ")
  name.empty? ? scope : "`#{name}` (#{scope})"
end

def audit(repo, workflows, policies, types, rulesets, fetcher, problems, warnings, summary)
  unresolved = []
  reported = contexts_in(workflows, unresolved, fetcher)
  exhausted = "searched #{workflows.keys.sort.join(', ')}"

  required_anywhere = []
  rulesets.each do |ruleset|
    if ruleset["enforcement"] == "disabled"
      warnings << "#{repo}: ruleset #{ruleset_label(ruleset)} is disabled, so it gates nothing"
    end

    required = required_contexts(ruleset)
    required_anywhere.concat(required)
    required.each do |context|
      next if reported.any? { |pattern| matches?(pattern, context) }

      caller = unresolved.find { |label| under?(context, label) }
      if caller
        warnings << "#{repo}: cannot verify `#{context}` required by ruleset " \
                    "#{ruleset_label(ruleset)}: the jobs of `#{caller}` are not readable from here"
      else
        problems << "#{repo}: ruleset #{ruleset_label(ruleset)} requires `#{context}`, which no job " \
                    "reports (#{exhausted})"
      end
    end
  end

  unused = reported.reject do |pattern|
    pattern.include?("${{") || required_anywhere.any? { |context| matches?(pattern, context) }
  end
  summary << "#{repo}: #{reported.size} check name(s) from #{workflows.size} workflow(s), " \
             "#{rulesets.size} ruleset(s), #{required_anywhere.size} required context(s)" \
             "#{unused.empty? ? '' : ". Reported but required nowhere: #{unused.sort.join(', ')}"}"

  audit_policies(repo, workflows, policies, types, problems, warnings, summary)
end

def consumers
  path = File.expand_path("../consumers.jsonl", __dir__)
  File.readlines(path, chomp: true).filter_map do |line|
    next if line.strip.empty?

    JSON.parse(line)
  end
end

def consumer_repos = consumers.map { |entry| entry["repo"] }

# The check types ci runs for a consumer, from the registry: whether a consumer needs an event policy
# is a property of what it asks ci to do, not of every workflow the templates left behind. A repo the
# registry does not name has no known types, and nil is judged as "may need one".
def consumer_types(repo) = consumers.find { |entry| entry["repo"] == repo }&.fetch("types", nil)

def step_summary(lines)
  body = lines.map { |line| "- #{line}" }.join("\n")
  path = ENV["GITHUB_STEP_SUMMARY"].to_s
  if path.empty?
    puts body
  else
    File.open(path, "a") { |f| f.puts("### Ruleset contexts\n\n#{body}\n") }
  end
end

def main(argv)
  workflows = rulesets = policies = repo = nil
  until argv.empty?
    case (flag = argv.shift)
    when "--repo" then repo = argv.shift
    when "--workflows" then workflows = argv.shift
    when "--rulesets" then rulesets = argv.shift
    when "--policies" then policies = argv.shift
    else raise Failure, "unknown argument: #{flag}"
    end
  end

  problems = []
  warnings = []
  summary = []
  fetcher = external_fetcher

  if workflows || rulesets
    raise Failure, "--workflows and --rulesets go together" unless workflows && rulesets

    tree = dir_workflows(workflows)
    exported = JSON.parse(File.read(rulesets))
    exported = exported["rulesets"] if exported.is_a?(Hash)
    listed = policies.nil? ? nil : JSON.parse(File.read(policies))
    listed = listed["policies"] if listed.is_a?(Hash)
    audit(repo || workflows, tree, listed, consumer_types(repo), exported, fetcher, problems,
          warnings, summary)
  else
    (repo ? [repo] : consumer_repos).each do |name|
      info = api_json("repos/#{name}")
      tree = repo_workflows(name, info.fetch("default_branch"))
      listed = api_json("repos/#{name}/rulesets")
      detail = listed.map { |ruleset| api_json("repos/#{name}/rulesets/#{ruleset.fetch('id')}") }
      # A second API, not a ruleset view of the same thing: `/rulesets` cannot see an Actions policy,
      # and this list needs `administration: write` where the ruleset read needs only read.
      #
      # The list carries names and ids only - its `conditions` and `rules` are null - and a policy
      # judged from that summary would look like one that applies to every workflow and allows every
      # event, which is the one answer that never fails. Each policy is read in full, as the rulesets
      # above are.
      event_policies = api_json("repos/#{name}/actions/policies").fetch("policies", []).map do |policy|
        api_json("repos/#{name}/actions/policies/#{policy.fetch('id')}")
      end
      audit(name, tree, event_policies, consumer_types(name), detail, fetcher, problems, warnings,
            summary)
    rescue Failure, KeyError => e
      problems << "#{name}: could not read its rulesets, Actions policies or workflows: #{e.message}"
    end
  end

  warnings.each { |warning| puts "::warning::#{warning}" }
  problems.each { |problem| puts "::error::#{problem}" }
  step_summary(summary + warnings + problems)

  puts(problems.empty? ? "every required context has a provider" : "#{problems.size} problem(s)")
  problems.empty? ? 0 : 1
end

exit(main(ARGV.dup))
