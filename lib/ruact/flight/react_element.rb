# frozen_string_literal: true

module Ruact
  module Flight
    # Represents a React element: <div>, <Component>, etc.
    # Wire format: ["$", type, key, props]
    class ReactElement
      attr_reader :type, :key, :props

      def initialize(type:, key: nil, props: {})
        @type = type
        @key = key
        @props = props
      end
    end

    # Represents a React Suspense boundary.
    # `fallback` is a ReactElement shown while the deferred content is loading.
    # `children` is the actual content (emitted as a deferred row after `delay` seconds).
    class SuspenseElement
      attr_reader :fallback, :children, :delay

      def initialize(fallback:, children:, delay: 1.5)
        @fallback  = fallback
        @children  = children
        @delay     = delay
      end
    end

    # Points to a "use client" module — will become an I row + $L<id> reference.
    class ClientReference
      attr_reader :module_id, :export_name

      def initialize(module_id:, export_name: "default")
        @module_id = module_id
        @export_name = export_name
      end
    end
  end
end
