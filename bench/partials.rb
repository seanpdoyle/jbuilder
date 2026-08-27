# frozen_string_literal: true

# Measures the cost of rendering Jbuilder partials.
#
#   bundle exec ruby bench/partials.rb            # timings
#   bundle exec ruby bench/partials.rb --allocs   # allocation counts
#
# Pass --json to emit machine readable results, which makes it easy to diff two
# revisions:
#
#   git stash && bundle exec ruby bench/partials.rb --json > /tmp/before.json

require_relative "support"
require "benchmark"
require "json"

# NOTE: intentionally not `include`d — BenchmarkSupport#render would end up on
# Object, and ActionView checks `options[:template].respond_to?(:render)`.
Bench = BenchmarkSupport

SCENARIOS = {
  "partial! in a loop" => {
    "source.json.jbuilder" => <<-JBUILDER
      json.posts do
        json.array! @posts do |post|
          json.partial! "post", post: post
        end
      end
    JBUILDER
  },

  "partial! with collection" => {
    "source.json.jbuilder" => <<-JBUILDER
      json.partial! "post", collection: @posts, as: :post
    JBUILDER
  },

  "array! with partial" => {
    "source.json.jbuilder" => <<-JBUILDER
      json.array! @posts, partial: "post", as: :post
    JBUILDER
  },

  "set! with partial collection" => {
    "source.json.jbuilder" => <<-JBUILDER
      json.posts @posts, partial: "post", as: :post
    JBUILDER
  },

  "partial! for an Active Model" => {
    "source.json.jbuilder" => <<-JBUILDER
      json.racers do
        json.array! @racers do |racer|
          json.partial! racer
        end
      end
    JBUILDER
  },

  "partial! with extra locals" => {
    "source.json.jbuilder" => <<-JBUILDER
      json.posts do
        json.array! @posts do |post|
          json.partial! "post", post: post, include_title: true
        end
      end
    JBUILDER
  },
}

ITERATIONS = Integer(ENV.fetch("ITERATIONS", 200))
TRIALS = Integer(ENV.fetch("TRIALS", 7))

views = SCENARIOS.transform_values do |templates|
  view = Bench.view_for(templates)
  view.assign(posts: Bench::POSTS, racers: Bench::RACERS)
  view
end

# Warm the template cache and make sure every scenario actually produces JSON.
views.each do |name, view|
  result = Bench.render(view)
  parsed = JSON.parse(result)
  raise "#{name} rendered nothing" if parsed.nil? || parsed.empty?
end

def measure_allocations
  GC.start
  GC.disable
  before = GC.stat(:total_allocated_objects)
  yield
  GC.stat(:total_allocated_objects) - before
ensure
  GC.enable
end

results = {}

if ARGV.include?("--allocs")
  views.each do |name, view|
      results[name] = measure_allocations { Bench.render(view) }
  end
else
  # Report the fastest of several trials: the slow ones are the machine's noise,
  # not the code's, and the minimum is what moves when the code actually changes.
  views.each do |name, view|
    2.times { ITERATIONS.times { Bench.render(view) } } # warmup

    best = TRIALS.times.map do
      GC.start
      Benchmark.realtime { ITERATIONS.times { Bench.render(view) } }
    end.min

    results[name] = (best / ITERATIONS) * 1_000_000 # microseconds per render
  end
end

if ARGV.include?("--json")
  puts JSON.pretty_generate(results)
else
  unit = ARGV.include?("--allocs") ? "objects/render" : "µs/render"
  width = results.keys.map(&:length).max
  results.each do |name, value|
    puts format("%-#{width}s  %10.1f %s", name, value, unit)
  end
end
