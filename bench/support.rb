# frozen_string_literal: true

# Shared setup for the partial rendering benchmarks.
#
# Boots a minimal Rails application (mirroring test/test_helper.rb) and exposes
# a view backed by an on-disk template resolver with template caching enabled,
# so that the numbers reflect production-style rendering rather than the
# uncached path used by the test suite.

require "bundler/setup"

require "tmpdir"
require "fileutils"

require "rails"
require "jbuilder"

require "active_support/cache/memory_store"
require "active_support/json"
require "active_model"
require "action_controller/railtie"
require "action_view/railtie"
require "action_view/test_case"

ENV["RAILS_ENV"] ||= "test"

class << Rails
  redefine_method :cache do
    @cache ||= ActiveSupport::Cache::MemoryStore.new
  end
end

Jbuilder::CollectionRenderer.collection_cache = Rails.cache

class Post < Struct.new(:id, :title, :body, :author_name)
  def cache_key
    "post-#{id}"
  end
end

class Racer < Struct.new(:id, :name)
  extend ActiveModel::Naming
  include ActiveModel::Conversion
end

# Rendering a partial emits `render_partial.action_view`, and Action View's log
# subscriber formats a line for every one of them at :debug. Default to :info so
# the numbers reflect a production log level; set LOG_LEVEL=debug to see what
# development pays. The log itself goes to /dev/null: formatting the line is the
# cost worth measuring, while a log file that grows by hundreds of megabytes over
# a run is not, and it makes back-to-back runs disagree with each other.
Class.new(Rails::Application) do
  config.secret_key_base = "secret"
  config.eager_load = false
  config.logger = ActiveSupport::Logger.new(File::NULL)
end.initialize!

# Set on the logger the subscribers are already holding, not on a replacement.
Rails.logger.level = ENV.fetch("LOG_LEVEL", "info")

ActionView::Base.inspect

module BenchmarkSupport
  extend self

  POST_PARTIAL = <<-JBUILDER
    json.extract! post, :id, :body
    json.title post.title if local_assigns.fetch(:include_title, false)
    json.author do
      first_name, last_name = post.author_name.split(nil, 2)
      json.first_name first_name
      json.last_name last_name
    end
  JBUILDER

  RACER_PARTIAL = <<-JBUILDER
    json.extract! racer, :id, :name
    json.highlighted local_assigns.fetch(:highlighted, false)
  JBUILDER

  PARTIALS = {
    "_partial.json.jbuilder" => "json.content content",
    "_post.json.jbuilder"    => POST_PARTIAL,
    "racers/_racer.json.jbuilder" => RACER_PARTIAL,
  }

  AUTHORS = [ "David Heinemeier Hansson", "Pavel Pravosud" ].cycle
  POSTS   = (1..100).collect { |i| Post.new(i, "Title #{i}", "Post ##{i}", AUTHORS.next) }
  RACERS  = (1..100).collect { |i| Racer.new(i, "Racer #{i}") }

  # Builds a view whose templates live on disk and whose compiled-template
  # cache is shared across renders, the way a booted application would.
  def view_class
    @view_class ||= ActionView::Base.with_empty_template_cache
  end

  def view_for(templates)
    dir = ::Dir.mktmpdir("jbuilder-bench")

    PARTIALS.merge(templates).each do |path, source|
      full = ::File.join(dir, path)
      ::FileUtils.mkdir_p(::File.dirname(full))
      ::File.write(full, source)
    end

    lookup_context = ActionView::LookupContext.new([ dir ], {}, [ "" ])
    controller = ActionView::TestCase::TestController.new

    view = view_class.new(lookup_context, {}, controller)

    def view.view_cache_dependencies; []; end
    def view.combined_fragment_cache_key(key) [ key ] end
    def view.cache_fragment_name(key, *) key end
    def view.fragment_name_with_digest(key) key end

    view
  end

  def render(view, template = "source")
    view.render(template: template)
  end
end
