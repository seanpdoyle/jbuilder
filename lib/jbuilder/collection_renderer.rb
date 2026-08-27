# frozen_string_literal: true

require 'delegate'
require 'action_view'
require 'action_view/renderer/collection_renderer'

class Jbuilder
  class CollectionRenderer < ::ActionView::CollectionRenderer # :nodoc:
    # Renders each element of the collection into its own scope on the builder,
    # so that a partial only ever sees the attributes it set itself.
    class ScopedIterator < ::SimpleDelegator # :nodoc:
      include Enumerable

      def initialize(obj, json)
        super(obj)
        @json = json
      end

      def each_with_info
        return enum_for(:each_with_info) unless block_given?

        json = @json

        __getobj__.each_with_info do |object, info|
          json.__send__(:_scope) { yield(object, info) }
        end
      end
    end

    private_constant :ScopedIterator

    def initialize(lookup_context, options)
      super
      @json = options[:locals].fetch(:json)
    end

    private

      def build_rendered_template(content, template, layout = nil)
        super(content || json.attributes!, template)
      end

      def build_rendered_collection(templates, _spacer)
        json.merge!(templates.map(&:body))
      end

      attr_reader :json

      def collection_with_template(view, template, layout, collection)
        super(view, template, layout, ScopedIterator.new(collection, @json))
      end
  end

  class EnumerableCompat < ::SimpleDelegator
    # Rails 6.1 requires this.
    def size(*args, &block)
      __getobj__.count(*args, &block)
    end
  end
end
