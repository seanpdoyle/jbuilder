# frozen_string_literal: true

require 'jbuilder/jbuilder'
require 'action_view'
require 'concurrent/map'

class Jbuilder
  # Renders a Jbuilder partial without going through ActionView::PartialRenderer.
  #
  # A Jbuilder partial writes into the builder handed down as the `json` local
  # rather than into an output buffer, so most of what ActionView::PartialRenderer
  # does around running the template -- allocating a renderer per call, deriving
  # the partial's local name, wrapping the result in a RenderedTemplate -- is
  # overhead here. What's left is looking the template up and running it, and the
  # lookup only has to happen once per shape of partial: a builder lives for
  # exactly one response, so memoizing on it is as good as memoizing per request.
  #
  # The `render_partial.action_view` notification is still emitted, so partials
  # rendered this way keep showing up in logs and in APM traces.
  #
  # Anything this renderer doesn't recognize is handed back to ActionView, which
  # keeps the unusual cases (layouts, an explicit `:object`, format overrides) on
  # the path they've always taken.
  class PartialRenderer # :nodoc:
    NO_DETAILS = {}.freeze
    NO_PREFIXES = [].freeze

    # ActionView derives a partial's local name from its path; that never changes
    # for a given path, so it's worth remembering across requests.
    LOCAL_NAMES = ::Concurrent::Map.new
    private_constant :LOCAL_NAMES

    def initialize(context)
      @context = context
      @lookup_context = nil
      @details_key = nil
      @templates = nil
    end

    # True when `options` describes a plain "render this partial with these
    # locals" call, which is the shape `json.partial!` produces. `:object`,
    # `:layout`, and the detail overrides (`:formats`, `:variants`, `:locale`)
    # all make ActionView resolve or decorate the partial in ways this renderer
    # deliberately doesn't reimplement.
    def renders?(options)
      ::String === options[:partial] &&
        !options.key?(:object) && !options.key?(:layout) &&
        !options.key?(:formats) && !options.key?(:variants) && !options.key?(:locale)
    end

    def render(options)
      locals = options[:locals]
      _render options[:partial], locals, locals.keys, options[:handlers]
    end

    # Renders the partial an Active Model object names through +to_partial_path+,
    # assigning the object to the local ActionView would have derived from that
    # path. Returns false when the path needs the controller namespace merged
    # into it, or isn't one a local can be named after, both of which are left
    # to ActionView.
    def render_object(object, locals)
      object = object.to_model if object.respond_to?(:to_model)
      path = object.to_partial_path

      return false unless _plain_object_path?(path)

      name = _local_name(path) or return false
      locals[name] = object
      _render path, locals, locals.keys, nil

      true
    end

    private

    def _render(partial, locals, template_keys, handlers)
      template = _template(partial, template_keys, handlers)

      ::ActiveSupport::Notifications.instrument(
        'render_partial.action_view',
        identifier: template.identifier,
        layout: nil,
        locals: locals
      ) do |payload|
        template.render(@context, locals)
        payload[:cache_hit] = @context.view_renderer.cache_hits[template.virtual_path]
      end
    end

    # Memoized three deep rather than under one composite key, because this runs
    # once per element of a collection and building the composite key costs more
    # than the extra hash hops.
    def _template(partial, template_keys, handlers)
      lookup_context = _lookup_context

      if (templates = @templates)
        by_partial = (templates[handlers] ||= {})
        by_keys = (by_partial[partial] ||= {})
        by_keys[template_keys] ||= _find_template(lookup_context, partial, template_keys, handlers)
      else
        _find_template(lookup_context, partial, template_keys, handlers)
      end
    end

    # Templates are memoized per lookup context and per details key -- the latter
    # covers a format, locale, or variant changing mid-render, and is nil inside
    # LookupContext#disable_cache, which is how ActionView asks for lookups not
    # to be reused at all.
    def _lookup_context
      lookup_context = @context.lookup_context
      details_key = lookup_context.details_key

      unless @lookup_context.equal?(lookup_context) && @details_key.equal?(details_key)
        @lookup_context = lookup_context
        @details_key = details_key
        @templates = details_key ? {} : nil
      end

      lookup_context
    end

    def _find_template(lookup_context, partial, template_keys, handlers)
      prefixes = partial.include?(?/) ? NO_PREFIXES : lookup_context.prefixes
      details = handlers ? { handlers: ::Kernel.Array(handlers) } : NO_DETAILS

      lookup_context.find_template(partial, prefixes, true, template_keys, details)
    end

    # ActionView prefixes an object's partial path with the controller namespace
    # when both are namespaced. That merge is rare and fiddly, so leave it to
    # ActionView.
    def _plain_object_path?(path)
      return true unless @context.prefix_partial_path_with_controller_namespace
      return true unless path.include?(?/)

      prefix = @context.lookup_context.prefixes.first
      prefix.nil? || !prefix.include?(?/)
    end

    def _local_name(path)
      LOCAL_NAMES.compute_if_absent(path) do
        base = path.end_with?(?/) ? '' : ::File.basename(path)
        name = base[/\A_?(.*?)(?:\.\w+)*\z/, 1]

        # ActionView raises its own ArgumentError for a path no local can be
        # named after; let it be the one to say so.
        name ? name.to_sym : false
      end
    end
  end
end
