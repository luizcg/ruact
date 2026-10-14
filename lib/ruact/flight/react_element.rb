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
    # `children` is the content, emitted as a deferred row after the shell: an
    # element tree, or a {DeferredContent} rendered when its row is due.
    # `delay` is the wait, in seconds, before that row when the response
    # streams; nil waits nothing.
    class SuspenseElement
      attr_reader :fallback, :children, :delay

      def initialize(fallback:, children:, delay: nil)
        @fallback  = fallback
        @children  = children
        @delay     = delay
      end
    end

    # The content of a Suspense boundary that has not been rendered yet: the
    # index of its block in the render context. The serializer never sees one —
    # it defers a boundary's children without looking at them, and the caller
    # of {Renderer#take_boundary} renders it.
    class DeferredContent
      attr_reader :index

      def initialize(index)
        @index = index
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
