# Merge the per-run result files of a GitHub Actions arena run into one
# results file, and write a Markdown ranking.
#
#   ruby .github/arena/merge.rb OUT.js SUMMARY.md RESULT.js...
require "json"

out, summary, *inputs = ARGV
abort "usage: merge.rb OUT.js SUMMARY.md RESULT.js..." if inputs.empty?

merged = {}
pcs = {}
inputs.sort.each do |path|
  j = JSON.parse(File.read(path))
  (j["runs"] || {}).each_key { |run| pcs[run] = j["pc"] }
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

runs = merged["runs"].keys
tests = merged["tests"]
time = ->(t, r) { v = (merged["#{t}-runtime"] || {})[r]; v.is_a?(Numeric) && v > 0 ? v : nil }
best = tests.to_h { |t| [t, runs.map { |r| time.(t, r) }.compact.min] }

rows = runs.map do |r|
  ok = tests.select { |t| time.(t, r) }
  ratios = ok.map { |t| time.(t, r) / best[t] }
  geo = ratios.empty? ? Float::INFINITY : Math.exp(ratios.sum { |x| Math.log(x) } / ratios.size)
  mems = ok.map { |t| merged["#{t}-mem-mb"]&.dig(r) }.compact
  {run: r, geo: geo, total: ok.sum { |t| time.(t, r) }, failed: tests.size - ok.size,
   wins: ok.count { |t| time.(t, r) == best[t] }, mem: mems.empty? ? 0 : mems.sum / mems.size,
   compile: merged.dig("compile-time-cold", r)}
end
rows.sort_by! { |x| [x[:failed] > 0 ? 1 : 0, x[:geo]] }

md = +"# LangArena on GitHub Actions\n\n"
md << "#{runs.size} runs, #{tests.size} tests, #{merged["date"]}. Runner CPU: #{merged["pc"]}.\n\n"
md << "Ranked by the geometric mean of each run's time relative to the fastest run on each test (1.00 = fastest everywhere). Runs with failed or missing tests are listed last; their mean covers only the tests that passed.\n\n"
md << "| # | Run | Relative time | Total runtime (s) | Fastest on | Failed | Avg memory (MB) | Cold compile (s) |\n|---|---|---|---|---|---|---|---|\n"
rows.each_with_index do |x, i|
  name = x[:run] =~ /\AZane/ ? "**#{x[:run]}**" : x[:run]
  geo = x[:geo].finite? ? format("%.2f", x[:geo]) : "-"
  compile = x[:compile].is_a?(Numeric) ? format("%.1f", x[:compile]) : "-"
  md << "| #{i + 1} | #{name} | #{geo} | #{format("%.1f", x[:total])} | #{x[:wins]} | #{x[:failed]} | #{format("%.0f", x[:mem])} | #{compile} |\n"
end

zane = runs.grep(/\AZane/)
zane.each do |z|
  md << "\n## #{z} per test\n\n| Test | Time (s) | Rank | Fastest | Relative |\n|---|---|---|---|---|\n"
  tests.each do |t|
    v = time.(t, z)
    unless v
      md << "| #{t} | failed | - | - | - |\n"
      next
    end
    ranked = runs.map { |r| [r, time.(t, r)] }.select { |_, s| s }.sort_by { |_, s| s }
    rank = ranked.index { |r, _| r == z } + 1
    md << "| #{t} | #{format("%.3f", v)} | #{rank}/#{ranked.size} | #{ranked[0][0]} | #{format("%.2f", v / best[t])} |\n"
  end
end
File.write(summary, md)
puts md.lines.first(12).join
