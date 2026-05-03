# frozen_string_literal: true

require "erb"

module Ruact
  # Internal — orchestrates the full server component render:
  #   ERB source → (preprocessor) → evaluated HTML → (HtmlConverter) → ReactElement tree
  #                                                                    → (Flight::Renderer) → wire bytes
  #
  # External code should use `Ruact::Controller#rsc_render` instead. `Ruact::RenderPipeline`
  # (and the rest of `Ruact::Flight::*` / `Ruact::Internal::*`) are not part of the public API
  # and may change between minor versions.
  #
  # Single entry point: {#render}.
  class RenderPipeline
    VALID_MODES = %i[string stream].freeze

    def initialize(manifest, controller_path: nil, logger: nil)
      @manifest         = manifest
      @controller_path  = controller_path
      @logger           = logger
    end

    # Render a server component tree to Flight wire format.
    #
    # @param input [Hash] selects the input shape; one of:
    #   - `{ erb: String, binding: Binding }` — render an ERB template within the given binding.
    #   - `{ html: String, render_context: Ruact::RenderContext }` — convert pre-rendered HTML
    #     (from ActionView) using a render context populated during ERB evaluation.
    # @param mode [Symbol] `:string` (returns full serialized String, deferred chunks inlined eagerly)
    #   or `:stream` (returns an Enumerator that yields Flight rows one at a time, deferred chunks
    #   delay — suitable for ActionController::Live streaming).
    # @return [String, Enumerator] depending on `mode`.
    # @raise [ArgumentError] if `input` mixes `:erb` and `:html` keys, omits the required sibling
    #   key (`:binding` for `:erb`, `:render_context` for `:html`), or `mode` is not in {VALID_MODES}.
    #
    # @example ERB source, buffered output
    #   pipeline.render({ erb: "<NavBar />", binding: ctx.instance_eval { binding } }, mode: :string)
    #   # => "0:[\"$\",\"div\",null,...]\n"
    #
    # @example Pre-rendered HTML, streaming output
    #   ctx = Ruact::RenderContext.new
    #   pipeline.render({ html: "<!-- __RSC_0__ -->", render_context: ctx }, mode: :stream)
    #   # => #<Enumerator: ...>  (yields Flight rows lazily)
    def render(input, mode: :string)
      validate_mode!(mode)
      enum = build_enum(input, streaming: mode == :stream)
      mode == :string ? enum.to_a.join : enum
    end

    private

    def validate_mode!(mode)
      return if VALID_MODES.include?(mode)

      raise ArgumentError,
            "ruact: unknown render mode #{mode.inspect}; expected one of #{VALID_MODES.inspect}"
    end

    def build_enum(input, streaming:)
      raise ArgumentError, "ruact: render input must be a Hash" unless input.is_a?(Hash)

      has_erb  = input.key?(:erb)
      has_html = input.key?(:html)

      if has_erb && has_html
        raise ArgumentError,
              "ruact: render input cannot mix :erb and :html keys (got both); choose one source shape"
      end

      unless has_erb || has_html
        raise ArgumentError,
              "ruact: render input must include either :erb (with sibling :binding) " \
              "or :html (with sibling :render_context)"
      end

      if has_erb
        binding_context = input[:binding]
        if binding_context.nil?
          raise ArgumentError,
                "ruact: render input { erb: ... } requires sibling :binding (Binding); got nil"
        end
        render_erb_enum(input[:erb], binding_context, streaming: streaming)
      else
        render_context = input[:render_context]
        if render_context.nil?
          raise ArgumentError,
                "ruact: render input { html: ... } requires sibling :render_context " \
                "(Ruact::RenderContext); got nil"
        end
        render_html_enum(input[:html], render_context, streaming: streaming)
      end
    end

    # ERB-source path: evaluate ERB, collect components into a fresh RenderContext via
    # injected `__rsc_component__` helper, then convert + serialize.
    def render_erb_enum(erb_source, binding_context, streaming:)
      strict     = Ruact.config.strict_serialization
      warning_cb = as_json_warning_callback

      Enumerator.new do |y|
        render_context = RenderContext.new
        transformed    = ErbPreprocessor.transform(erb_source)
        receiver       = binding_context.eval("self")
        prev_ctx       = receiver.instance_variable_get(:@__ruact_render_context__)
        inject_helper!(binding_context, render_context)
        html =
          begin
            ERB.new(transformed).result(binding_context)
          ensure
            receiver.instance_variable_set(:@__ruact_render_context__, prev_ctx)
          end

        registry = render_context.components.map do |entry|
          ref = @manifest.reference_for(entry[:name], controller_path: @controller_path)
          { token: entry[:token], name: entry[:name], ref: ref, props: entry[:props] }
        end

        root_element = HtmlConverter.convert(html, registry)

        Flight::Renderer.each(root_element, @manifest,
                              strict_serialization: strict,
                              on_as_json_warning: warning_cb,
                              streaming: streaming) { |row| y << row }
      end
    end

    # HTML path: input HTML is already rendered by ActionView; the supplied RenderContext
    # holds the components encountered during ERB evaluation. Registry is captured eagerly so
    # the caller may discard the RenderContext immediately after `render` returns — the
    # returned Enumerator does not reference the RenderContext.
    def render_html_enum(html, render_context, streaming:)
      registry = render_context.components.map do |entry|
        ref = @manifest.reference_for(entry[:name], controller_path: @controller_path)
        { token: entry[:token], name: entry[:name], ref: ref, props: entry[:props] }
      end
      strict     = Ruact.config.strict_serialization
      warning_cb = as_json_warning_callback

      Enumerator.new do |y|
        root_element = HtmlConverter.convert(html, registry)
        Flight::Renderer.each(root_element, @manifest,
                              strict_serialization: strict,
                              on_as_json_warning: warning_cb,
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

    # Install __rsc_component__ on the binding's receiver and stash the active
    # render context on the receiver as @__ruact_render_context__. The singleton
    # method reads the ivar dynamically, so nested renders sharing the same
    # receiver (e.g., inner pipeline.render from inside ERB) see whatever context
    # is current at invocation time — render_erb_enum wraps ERB evaluation in a
    # save/restore block so the outer render's context is restored afterward.
    # Defining the singleton method is idempotent — re-defining on a nested
    # call would not change behaviour, but skipping it avoids needless work.
    def inject_helper!(binding_context, render_context)
      receiver = binding_context.eval("self")
      receiver.instance_variable_set(:@__ruact_render_context__, render_context)
      return if receiver.respond_to?(:__rsc_component__)

      receiver.define_singleton_method(:__rsc_component__) do |name, props = {}|
        ctx = instance_variable_get(:@__ruact_render_context__)
        raise Ruact::Error, "ruact: __rsc_component__ called outside an active render context" if ctx.nil?

        token = ctx.register(name, props)
        "<!-- #{token} -->"
      end
    end
  end
end
