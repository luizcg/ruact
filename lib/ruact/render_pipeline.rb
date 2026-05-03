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
    # **Internal API.** External code should call `Ruact::Controller#rsc_render` instead.
    # `Ruact::RenderPipeline` is not part of the public API and may change between minor
    # versions without deprecation. Reach into it only when extending the gem itself.
    #
    # @param input [Hash] selects the input shape — exactly one of:
    #   - `{ erb: String, binding: Binding }` — render an ERB template within the given binding.
    #     Both keys required; `:erb` must be a `String`, `:binding` must be a `Binding`.
    #   - `{ html: String, render_context: Ruact::RenderContext }` — convert pre-rendered HTML
    #     (from ActionView) using a render context populated during ERB evaluation.
    #     Both keys required; `:html` must be a `String`, `:render_context` must be a
    #     `Ruact::RenderContext`.
    #   Extra keys beyond the two-key shapes above are rejected with `ArgumentError`.
    # @param mode [Symbol] one of:
    #   - `:string` — returns the full serialized `String`. Deferred chunks are inlined
    #     eagerly (no Suspense delay). Suitable for buffered HTTP responses.
    #   - `:stream` — returns an `Enumerator` that yields Flight rows one at a time.
    #     Deferred chunks delay. Suitable for `ActionController::Live` streaming.
    # @return [String, Enumerator] depending on `mode`.
    # @raise [ArgumentError] when:
    #   - `input` is not a `Hash`,
    #   - `input` mixes `:erb` and `:html` keys,
    #   - `input` omits both `:erb` and `:html`,
    #   - the required sibling key is missing or has the wrong type
    #     (`:binding` must be a `Binding`; `:render_context` must be a `Ruact::RenderContext`),
    #   - `:erb` or `:html` is not a `String`,
    #   - `input` contains extra keys beyond the documented shapes,
    #   - `mode` is not in {VALID_MODES}.
    #   All `ArgumentError` messages name the offending input and reference
    #   `RenderPipeline#render` for the canonical contract.
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

    ALLOWED_INPUT_KEYS = %i[erb binding html render_context].freeze
    private_constant :ALLOWED_INPUT_KEYS

    DOCSTRING_REF = "see RenderPipeline#render docstring for the canonical contract"
    private_constant :DOCSTRING_REF

    def validate_mode!(mode)
      return if VALID_MODES.include?(mode)

      raise ArgumentError,
            "ruact: unknown render mode #{mode.inspect}; expected one of #{VALID_MODES.inspect} " \
            "(#{DOCSTRING_REF})"
    end

    def build_enum(input, streaming:)
      unless input.is_a?(Hash)
        raise ArgumentError,
              "ruact: render input must be a Hash; got #{input.class} (#{DOCSTRING_REF})"
      end

      extra = input.keys - ALLOWED_INPUT_KEYS
      unless extra.empty?
        raise ArgumentError,
              "ruact: render input contains unsupported keys: #{extra.inspect}; " \
              "expected only #{ALLOWED_INPUT_KEYS.inspect} (#{DOCSTRING_REF})"
      end

      has_erb  = input.key?(:erb)
      has_html = input.key?(:html)

      if has_erb && has_html
        raise ArgumentError,
              "ruact: render input cannot mix :erb and :html keys (got both); choose one source shape " \
              "(#{DOCSTRING_REF})"
      end

      unless has_erb || has_html
        raise ArgumentError,
              "ruact: render input must include either :erb (with sibling :binding) " \
              "or :html (with sibling :render_context) (#{DOCSTRING_REF})"
      end

      if has_erb
        validate_erb_shape!(input)
        render_erb_enum(input[:erb], input[:binding], streaming: streaming)
      else
        validate_html_shape!(input)
        render_html_enum(input[:html], input[:render_context], streaming: streaming)
      end
    end

    def validate_erb_shape!(input)
      erb = input[:erb]
      unless erb.is_a?(String)
        raise ArgumentError,
              "ruact: render input :erb must be a String; got #{erb.class} (#{DOCSTRING_REF})"
      end
      unless input.key?(:binding)
        raise ArgumentError,
              "ruact: render input { erb: ... } requires sibling :binding (Binding) (#{DOCSTRING_REF})"
      end
      bnd = input[:binding]
      return if bnd.is_a?(Binding)

      raise ArgumentError,
            "ruact: render input :binding must be a Binding; got #{bnd.class} (#{DOCSTRING_REF})"
    end

    def validate_html_shape!(input)
      html = input[:html]
      unless html.is_a?(String)
        raise ArgumentError,
              "ruact: render input :html must be a String; got #{html.class} (#{DOCSTRING_REF})"
      end
      unless input.key?(:render_context)
        raise ArgumentError,
              "ruact: render input { html: ... } requires sibling :render_context " \
              "(Ruact::RenderContext) (#{DOCSTRING_REF})"
      end
      ctx = input[:render_context]
      return if ctx.is_a?(RenderContext)

      raise ArgumentError,
            "ruact: render input :render_context must be a Ruact::RenderContext; " \
            "got #{ctx.class} (#{DOCSTRING_REF})"
    end

    # ERB-source path: evaluate ERB, collect components into a fresh RenderContext via
    # injected `__rsc_component__` helper, then convert + serialize.
    #
    # NB: `Ruact.config.strict_serialization` and the `as_json` warning callback are read
    # inside the Enumerator block (consumption time), preserving the legacy `_stream`
    # behavior — config changes between `#render` returning and the Enumerator being
    # consumed are observable.
    def render_erb_enum(erb_source, binding_context, streaming:)
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
                              strict_serialization: Ruact.config.strict_serialization,
                              on_as_json_warning: as_json_warning_callback,
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
