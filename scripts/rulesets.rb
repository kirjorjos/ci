#!/usr/bin/env ruby
# frozen_string_literal: true

# Fails when a ruleset requires a status context no workflow job can report, and reports the mirror
# of that mistake: a ruleset nobody enforces gates nothing, and a context no ruleset requires is
# dead weight.
#
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
#   ruby scripts/rulesets.rb --workflows .github/workflows --rulesets /tmp/rulesets.json
#
# The offline form reads one tree and one exported ruleset list, which is how the matching rules are
# exercised without creating a ruleset to break.
#
# Reading another repository's rulesets needs `administration: read` on the app; the workflow that
# runs this asks for it.

require "json"
require "open3"
require "yaml"

# `${{ matrix.loader }}` and friends: one check per expansion, so the name is matched as a pattern.
MATRIX = /\$\{\{[^}]*\}\}/
# A reusable workflow can call another; a cycle or a runaway chain is a defect, not a depth to follow.
MAX_DEPTH = 5
# `owner/repo/.github/workflows/file.yml@ref` - a reusable workflow outside this repository.
EXTERNAL = %r{\A(?<repo>[\w.-]+/[\w.-]+)/(?<path>\.github/workflows/[\w./-]+\.ya?ml)@(?<ref>.+)\z}

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
def dir_workflows(dir)
  root = dir.sub(%r{/?\.github/workflows/?\z}, "").chomp("/")
  keys = Dir.glob(File.join(dir, "**", "*.{yml,yaml}")).map { |p| p.delete_prefix("#{root}/") }
  # A caller given as `--workflows .github/workflows` still names its files `./.github/workflows/x.yml`.
  keys.to_h { |key| [key, File.read(File.join(root, key))] }
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

# `${{ ... }}` matches whatever the matrix expanded it to; everything else is literal.
def matches?(pattern, context)
  parts = pattern.split(MATRIX).map { |part| Regexp.escape(part) }
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

def audit(repo, workflows, rulesets, fetcher, problems, warnings, summary)
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
end

def consumer_repos
  path = File.expand_path("../consumers.jsonl", __dir__)
  File.readlines(path, chomp: true).filter_map do |line|
    next if line.strip.empty?

    JSON.parse(line)["repo"]
  end
end

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
  workflows = rulesets = repo = nil
  until argv.empty?
    case (flag = argv.shift)
    when "--repo" then repo = argv.shift
    when "--workflows" then workflows = argv.shift
    when "--rulesets" then rulesets = argv.shift
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
    audit(repo || workflows, tree, exported, fetcher, problems, warnings, summary)
  else
    (repo ? [repo] : consumer_repos).each do |name|
      info = api_json("repos/#{name}")
      tree = repo_workflows(name, info.fetch("default_branch"))
      listed = api_json("repos/#{name}/rulesets")
      detail = listed.map { |ruleset| api_json("repos/#{name}/rulesets/#{ruleset.fetch('id')}") }
      audit(name, tree, detail, fetcher, problems, warnings, summary)
    rescue Failure, KeyError => e
      problems << "#{name}: could not read its rulesets or workflows: #{e.message}"
    end
  end

  warnings.each { |warning| puts "::warning::#{warning}" }
  problems.each { |problem| puts "::error::#{problem}" }
  step_summary(summary + warnings + problems)

  puts(problems.empty? ? "every required context has a provider" : "#{problems.size} problem(s)")
  problems.empty? ? 0 : 1
end

exit(main(ARGV.dup))
