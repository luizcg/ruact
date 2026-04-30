# frozen_string_literal: true

require "erb"

module Ruact
  # Orchestrates the full server component render:
  #   ERB source → (preprocessor) → evaluated HTML → (HtmlConverter) → ReactElement tree
  #                                                                    → (Flight::Renderer) → wire bytes
  #
  # Two entry points:
  #   call/stream — full pipeline from ERB source (used in unit tests and legacy path)
  #   from_html   — takes pre-rendered HTML from ActionView (used by Controller#rsc_render)
  class RenderPipeline
    def initialize(manifest, controller_path: nil, logger: nil)
      @manifest         = manifest
      @controller_path  = controller_path
      @logger           = logger
    end

    # Render ERB source within a given binding, return Flight wire format string.
    # Deferred chunk delays are skipped — suitable for buffered responses (HTML shell).
    def call(erb_source, binding_context)
      _stream(erb_source, binding_context, streaming: false).to_a.join
    end

    # Render ERB source and return an Enumerator that yields Flight rows one at a time.
    # Deferred chunk delays ARE applied — suitable for ActionController::Live streaming.
    def stream(erb_source, binding_context)
      _stream(erb_source, binding_context, streaming: true)
    end

    # Convert pre-rendered HTML (from ActionView) to Flight wire rows.
    #
    # IMPORTANT — Eager registry capture: render_context.components is read
    # immediately when this method is called, before the Enumerator is returned.
    # This allows the caller to discard the render_context right after from_html
    # returns without affecting the captured registry — the returned Enumerator
    # does NOT reference render_context at all, only the eagerly-captured local.
    def from_html(html, render_context:, streaming: false)
      registry = render_context.components.map do |entry|
        ref = @manifest.reference_for(entry[:name], controller_path: @controller_path)
        { token: entry[:token], name: entry[:name], ref: ref, props: entry[:props] }
      end
      strict = Ruact.config.strict_serialization
      warning_cb = as_json_warning_callback

      Enumerator.new do |y|
        root_element = HtmlConverter.convert(html, registry)
        Flight::Renderer.each(root_element, @manifest,
                              strict_serialization: strict,
                              on_as_json_warning: warning_cb,
                              streaming: streaming) { |row| y << row }
      end
    end

    private

    def _stream(erb_source, binding_context, streaming: false)
      Enumerator.new do |y|
        render_context = RenderContext.new
        transformed = ErbPreprocessor.transform(erb_source)
        inject_helper!(binding_context, render_context)
        html = ERB.new(transformed).result(binding_context)

        registry = render_context.components.map do |entry|
          ref = @manifest.reference_for(entry[:name], controller_path: @controller_path)
          { token: entry[:token], name: entry[:name], ref: ref, props: entry[:props] }
        end

        root_element = HtmlConverter.convert(html, registry)

        Flight::Renderer.each(root_element, @manifest,
                              strict_serialization: Ruact.config.strict_serialization,
                              on_as_json_warning: as_json_warning_callback,
                              streaming: streaming) { |row| y << row }
      end
    end

    def as_json_warning_callback
      return nil if @logger.nil?

      lambda do |class_name, attrs|
        @logger.warn(
          "[ruact] WARNING: #{class_name} serialized via as_json — " \
          "ALL attributes exposed to client: #{attrs}. " \
          "Use `include Ruact::Serializable` with `rsc_props` for explicit control"
        )
      end
    end

    # Define __rsc_component__ as a singleton method on the binding's receiver,
    # closing over render_context so registration writes to this render's
    # context only — no Thread.current, no shared state.
    def inject_helper!(binding_context, render_context)
      receiver = binding_context.eval("self")
      receiver.define_singleton_method(:__rsc_component__) do |name, props = {}|
        token = render_context.register(name, props)
        "<!-- #{token} -->"
      end
    end
  end
end
