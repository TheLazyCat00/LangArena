# Merge the per-run result files of a GitHub Actions arena run into one
# results file, and write a Markdown ranking.
#
#   ruby .github/arena/merge.rb OUT.js SUMMARY.md PARTS_DIR
#
# PARTS_DIR holds one directory per job, each with run.js (the run's results)
# and ref.js (C/Clang's, measured on the same runner; absent for the C/Clang
# job itself). Hosted runners differ in CPU, so runs are ranked by their time
# relative to their own runner's C/Clang, not by raw times across machines.
require "json"

REFERENCE = "C/Clang"
FLOOR = 1e-4 # seconds; a fixture test can report 0.000s

out, summary, parts = ARGV
abort "usage: merge.rb OUT.js SUMMARY.md PARTS_DIR" unless parts

jobs = Dir.glob(File.join(parts, "**", "run.js")).sort.map do |path|
  ref = File.join(File.dirname(path), "ref.js")
  {run: JSON.parse(File.read(path)), ref: File.file?(ref) ? JSON.parse(File.read(ref)) : nil}
end
abort "no run.js files under #{parts}" if jobs.empty?

merged = {}
pcs = {}
jobs.each do |job|
  j = job[:run]
  j["runs"].each_key { |run| pcs[run] = j["pc"] }
  j.each do |key, value|
    case value
    when Hash then (merged[key] ||= {}).merge!(value)
    when Array then merged[key] = ((merged[key] || []) | value)
    else merged[key] ||= value
    end
  end
end
merged["langs"] = (merged["langs"] || []).sort
merged["uname-name"] = "github-actions"
merged["pc-by-run"] = pcs
distinct = pcs.values.uniq
merged["pc"] = distinct.size == 1 ? distinct[0] : "mixed: #{distinct.join(" / ")}"
File.write(out, JSON.pretty_generate(merged))

def time(j, test, run)
  v = (j["#{test}-runtime"] || {})[run]
  v.is_a?(Numeric) ? [v, FLOOR].max : nil
end

tests = merged["tests"]
rows = jobs.map do |job|
  j = job[:run]
  run = j["runs"].keys.first
  ref = job[:ref] || j
  passed = tests.select { |t| time(j, t, run) }
  paired = passed.select { |t| time(ref, t, REFERENCE) }
  ratios = paired.map { |t| time(j, t, run) / time(ref, t, REFERENCE) }
  geo = ratios.empty? ? Float::INFINITY : Math.exp(ratios.sum { |x| Math.log(x) } / ratios.size)
  mems = passed.map { |t| j["#{t}-mem-mb"]&.dig(run) }.compact
  {run: run, j: j, ref: ref, geo: geo, failed: tests.size - passed.size, pc: j["pc"],
   total: passed.sum { |t| time(j, t, run) }, mem: mems.empty? ? 0 : mems.sum / mems.size,
   compile: j.dig("compile-time-cold", run)}
end
rows.sort_by! { |x| [x[:failed] > 0 ? 1 : 0, x[:geo]] }

fmt = ->(x, spec) { x.is_a?(Numeric) && x.finite? ? format(spec, x) : "-" }
md = +"# LangArena on GitHub Actions\n\n"
md << "#{rows.size} runs, #{tests.size} tests, #{merged["date"]}.\n\n"
md << "Each job ran its run and #{REFERENCE} on the same runner. **Relative time** is the geometric mean, over the tests, of the run's time divided by that runner's #{REFERENCE} time (below 1.00 is faster than #{REFERENCE}), so differences between runner CPUs cancel out. Runs with failed tests are listed last; their mean covers only the tests that passed. Total runtime and memory are raw values from each run's own runner.\n\n"
md << "| # | Run | Relative time | Failed | Total runtime (s) | Avg memory (MB) | Cold compile (s) | Runner CPU |\n|---|---|---|---|---|---|---|---|\n"
rows.each_with_index do |x, i|
  name = x[:run] =~ /\AZane/ ? "**#{x[:run]}**" : x[:run]
  md << "| #{i + 1} | #{name} | #{fmt.(x[:geo], "%.2f")} | #{x[:failed]} | #{fmt.(x[:total], "%.1f")} | #{fmt.(x[:mem], "%.0f")} | #{fmt.(x[:compile], "%.1f")} | #{x[:pc]} |\n"
end

rows.select { |x| x[:run] =~ /\AZane/ }.each do |z|
  md << "\n## #{z[:run]} per test\n\nTimes relative to each run's own runner's #{REFERENCE}; rank among the runs that passed the test.\n\n"
  md << "| Test | Time (s) | vs #{REFERENCE} | Rank | Fastest run (vs #{REFERENCE}) |\n|---|---|---|---|---|\n"
  tests.each do |t|
    mine = time(z[:j], t, z[:run])
    unless mine
      md << "| #{t} | failed | - | - | - |\n"
      next
    end
    rel = rows.map do |x|
      v = time(x[:j], t, x[:run])
      r = time(x[:ref], t, REFERENCE)
      v && r ? [x[:run], v / r] : nil
    end.compact.sort_by { |_, v| v }
    own = rel.find { |r, _| r == z[:run] }
    rank = own ? "#{rel.index(own) + 1}/#{rel.size}" : "-"
    md << "| #{t} | #{format("%.3f", mine)} | #{own ? format("%.2f", own[1]) : "-"} | #{rank} | #{rel[0][0]} (#{format("%.2f", rel[0][1])}) |\n"
  end
end
File.write(summary, md)
puts md.lines.first(10).join
