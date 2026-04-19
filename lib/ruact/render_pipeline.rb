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
    # IMPORTANT — Eager registry capture: ComponentRegistry.components is read
    # immediately when this method is called, before the Enumerator is returned.
    # This allows the caller to call ComponentRegistry.reset right after from_html
    # returns (inside an ensure block) without affecting the captured registry.
    #
    # The returned Enumerator does NOT reference ComponentRegistry at all —
    # only the eagerly-captured +registry+ local variable.
    def from_html(html, streaming: false)
      registry = ComponentRegistry.components.map do |entry|
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
        ComponentRegistry.start
        begin
          transformed = ErbPreprocessor.transform(erb_source)
          inject_helper!(binding_context)
          html = ERB.new(transformed).result(binding_context)

          registry = ComponentRegistry.components.map do |entry|
            ref = @manifest.reference_for(entry[:name], controller_path: @controller_path)
            { token: entry[:token], name: entry[:name], ref: ref, props: entry[:props] }
          end

          root_element = HtmlConverter.convert(html, registry)

          Flight::Renderer.each(root_element, @manifest,
                                strict_serialization: Ruact.config.strict_serialization,
                                on_as_json_warning: as_json_warning_callback,
                                streaming: streaming) { |row| y << row }
        ensure
          ComponentRegistry.reset
        end
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

    # Define __rsc_component__ in the ERB binding so it can be called.
    def inject_helper!(binding_context)
      binding_context.eval(<<~RUBY)
        def __rsc_component__(name, props = {})
          token = ::Ruact::ComponentRegistry.register(name, props)
          "<!-- \#{token} -->"
        end
      RUBY
    end
  end
end
