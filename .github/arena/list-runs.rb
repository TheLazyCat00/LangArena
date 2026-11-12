# Print the benchmark runs as a GitHub Actions matrix (JSON), without running
# benchmarks.rb itself, whose top level calls docker.
#
#   ruby .github/arena/list-runs.rb [GROUP] [NAME_REGEX]
#
# GROUP is prod (default), hack or all; NAME_REGEX filters run names.
require "json"

src = File.read(File.join(__dir__, "../../benchmarks.rb"))
DOTNET_RUNTIME = "linux-x64"
IS_VERBOSE = false
eval(src[src.index("class Run")...src.index("RUNS = [")])
eval(src[src.index("RUNS = [")...src.index("run_names = {}")])

group = (ARGV[0] || "prod").to_sym
filter = ARGV[1] && !ARGV[1].empty? ? Regexp.new(ARGV[1]) : nil
runs = RUNS.select { |r| (group == :all || r.group == group) && (!filter || r.name =~ filter) }
abort "no runs selected" if runs.empty?
puts JSON.generate(runs.map { |r| {"name" => r.name, "container" => r.container, "lang" => r.lang} })
