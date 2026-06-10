# frozen_string_literal: true

require "action_controller"

require_relative "error_rendering"
require_relative "bucket_two_payload"
require_relative "query_context"

module Ruact
  module ServerFunctions
    # Story 9.4 (D2) — generates the INTERNAL dispatch controller backing the
    # routes the `ruact_queries` macro draws: one controller subclass PER
    # {Ruact::Query} subclass, with one action per public query method. The
    # per-class shape is what makes the AC4 callback opt-out scopable — a
    # `ruact_skip_before_action` on one query class lands on that class's
    # controller only, and `only:`/`except:` options scope it further to
    # individual query methods (each method is one action).
    #
    # The controller inherits `Ruact.config.query_parent_controller`
    # (default `ApplicationController`), resolved LAZILY here — at route-draw
    # time, when the host's constants exist — never at gem-load or configure
    # time. The host's REAL callback chain therefore runs before the query
    # class is instantiated (FR89). The dev never sees this controller; it is
    # named under this module (e.g.
    # `Ruact::ServerFunctions::QueryDispatch::CatalogQueryController`) only so
    # Rails' string-based route resolution (`to: "…/catalog_query#categories"`)
    # and `rails routes` output stay legible.
    #
    # Regeneration is idempotent: every `ruact_queries` evaluation (boot AND
    # every dev-mode routes reload) rebuilds the constant from the query
    # class's CURRENT state, and the query class itself is re-constantized per
    # request, so code reloading never serves a stale class.
    module QueryDispatch
      # Instance-level dispatch plumbing shared by every generated controller.
      # Included into the generated subclass, so these definitions override
      # anything the parent chain provides (notably the {Ruact::Server} gates,
      # when the host's ApplicationController happens to include the mutation
      # concern).
      module Dispatching
        # The Method#parameters types that mark keyword arguments (D7).
        KEYWORD_PARAM_TYPES = %i[key keyreq].freeze

        private

        # The action body of every query action: fresh context + fresh query
        # instance per request (NFR8), return value serialized through the
        # SAME policy Bucket 2 applies to ivars (D6). Encoded explicitly so a
        # scalar String/nil return still renders valid JSON (`"hi"` / `null`),
        # which `render json:` alone would pass through raw.
        def __ruact_dispatch_query(query_method)
          query_class = self.class.__ruact_query_class
          query = query_class.new(QueryContext.new(controller: self))
          result = query.public_send(query_method, **__ruact_query_kwargs(query, query_method))
          serialized = BucketTwoPayload.serialize_value(result, strict: Ruact.config.strict_serialization)
          render json: ActiveSupport::JSON.encode(serialized)
        end

        # D7 — minimal, best-effort param passing: only the keyword arguments
        # the query method declares, read by name from the GET query params
        # (values arrive as Strings). The strict FR88 sanitization contract
        # (primitive allowlist, reject objects, 400 on invalid) is Story 9.5,
        # coupled to the `useQuery` wire format.
        def __ruact_query_kwargs(query, query_method)
          query.method(query_method).parameters.each_with_object({}) do |(type, name), kwargs|
            next unless KEYWORD_PARAM_TYPES.include?(type)

            kwargs[name] = params[name.to_s] if params.key?(name.to_s)
          end
        end

        # D5 — the {Ruact::Server} mutation gate returns false for GET/HEAD so
        # GET *pages* keep stock Rails errors; query dispatch requests are GET
        # *function calls*, so the structured 8.4 payload must render here.
        # `Ruact::ConfigurationError` still re-raises — a misconfiguration is
        # a loud setup failure, never a disguised runtime 500 (the same rule
        # the mutation concern enforces).
        def __ruact_render_structured_error?(error)
          !error.is_a?(Ruact::ConfigurationError)
        end
      end

      class << self
        # Builds (or rebuilds) the dispatch controller for +query_class+ and
        # installs it under this module's namespace, where the route target
        # string from {.route_target_for} resolves to it.
        #
        # @param query_class [Class] a {Ruact::Query} subclass
        # @return [Class] the generated controller
        # @raise [Ruact::ConfigurationError] when the parent controller cannot
        #   be resolved or +query_class+ is anonymous
        def controller_for(query_class)
          *namespace_segments, base = constant_segments(query_class)
          namespace = ensure_namespace(namespace_segments)
          const_name = "#{base}Controller"
          namespace.send(:remove_const, const_name) if namespace.const_defined?(const_name, false)
          namespace.const_set(const_name, build_controller(query_class))
        end

        # The `to:` route target for +query_class+'s generated controller —
        # the underscored constant path Rails camelizes back at dispatch time.
        # The query class's namespace is PRESERVED (review round 4): a nested
        # path, never flattened, so two classes whose names differ only in
        # namespace boundary (`Admin::CatalogQuery` vs `AdminCatalogQuery`)
        # map to DISTINCT controllers and can never cross-wire — collision is
        # impossible by construction, across any number of RouteSets / engines.
        #
        # @param query_class [Class] a {Ruact::Query} subclass
        # @return [String] e.g. `"ruact/server_functions/query_dispatch/admin/catalog_query"`
        def route_target_for(query_class)
          "ruact/server_functions/query_dispatch/#{path_segments(query_class).join('/')}"
        end

        private

        # The underscored route-path segments for +query_class+
        # (`Admin::CatalogQuery` → `["admin", "catalog_query"]`).
        def path_segments(query_class)
          base_segments(query_class).map(&:underscore)
        end

        # The generated controller's constant-name segments — derived from the
        # SAME underscored path the route target uses, then `camelize`d
        # (review round 5). Deriving both directions from one underscored form
        # via the shared global inflector guarantees the route target Rails
        # `camelize`s at dispatch time resolves to EXACTLY this constant,
        # regardless of how the query class spelled an acronym or how the host
        # configured `inflect.acronym` (`APIProbe::CatalogQuery` and the route
        # `.../api_probe/catalog_query` both canonicalize identically). Using
        # the raw class spelling instead would 404 acronym constants with the
        # default inflector.
        def constant_segments(query_class)
          path_segments(query_class).map(&:camelize)
        end

        # The query class's fully-qualified name split into constant segments
        # (`Admin::CatalogQuery` → `["Admin", "CatalogQuery"]`). The namespace
        # is preserved so the generated controller lives at a nested,
        # collision-free constant path under {QueryDispatch}.
        def base_segments(query_class)
          name = query_class.name
          unless name
            raise Ruact::ConfigurationError,
                  "ruact_queries cannot mount an anonymous Ruact::Query subclass — " \
                  "assign it to a constant (e.g. `class CatalogQuery < ApplicationQuery`)."
          end

          name.split("::")
        end

        # Walks (creating as needed) the nested module path under {QueryDispatch}
        # that mirrors the query class's namespace, returning the innermost
        # module the controller constant is set on. Idempotent — reuses existing
        # modules so repeated draws (boot + dev reloads) never duplicate them.
        def ensure_namespace(segments)
          segments.reduce(self) do |mod, segment|
            if mod.const_defined?(segment, false)
              mod.const_get(segment, false)
            else
              mod.const_set(segment, Module.new)
            end
          end
        end

        # Lazy resolution of `Ruact.config.query_parent_controller` (AC2). Both
        # failure shapes are configuration-time errors raised at route-draw —
        # a typo'd name or a non-controller class must never reach a request.
        def resolve_parent_controller
          name = Ruact.config.query_parent_controller
          parent = begin
            name.constantize
          rescue NameError
            raise Ruact::ConfigurationError,
                  "ruact_queries: Ruact.config.query_parent_controller = #{name.inspect} does not " \
                  "resolve to a constant. Define that controller, or point query_parent_controller " \
                  "at an existing one in config/initializers/ruact.rb."
          end

          unless parent.is_a?(Class) && parent <= ActionController::Metal
            raise Ruact::ConfigurationError,
                  "ruact_queries: Ruact.config.query_parent_controller = #{name.inspect} resolved to " \
                  "#{parent.inspect}, which is not an ActionController class."
          end

          parent
        end

        def build_controller(query_class)
          query_class_name = query_class.name

          controller = Class.new(resolve_parent_controller) do
            include Ruact::ServerFunctions::ErrorRendering
            include Dispatching

            # Re-constantized on every read so dev-mode code reloading of the
            # query class can never leave the controller holding a stale ref.
            define_singleton_method(:__ruact_query_class) { query_class_name.constantize }

            # AC5 — the salvaged 8.4 error chain, with the same front-loading
            # trick as Ruact::Server: handlers the parent chain registered
            # (inherited OR declared later) stay more recent and keep
            # precedence; the structured renderer only catches what the host
            # did not.
            inherited_handlers = rescue_handlers
            rescue_from StandardError, with: :__ruact_render_action_error
            self.rescue_handlers = (rescue_handlers - inherited_handlers) + inherited_handlers
          end

          define_query_actions(controller, query_class)
          apply_skips(controller, query_class)
          controller
        end

        # Review round 1 (finding 1) — a query method whose name already exists
        # anywhere on the generated controller chain (`params`, `render`,
        # `session`, `process`, the gem's own `__ruact_*` plumbing, …) would
        # OVERRIDE that method when installed as an action, corrupting request
        # handling (e.g. `def params` shadows `ActionController#params` and
        # recurses through the dispatch path). Reject at route-draw with a
        # legible error instead of failing at the first request.
        def define_query_actions(controller, query_class)
          query_class.public_instance_methods(false).each do |query_method|
            if controller.method_defined?(query_method) || controller.private_method_defined?(query_method)
              raise Ruact::ConfigurationError,
                    "ruact_queries: query method :#{query_method} on #{query_class.name} is already " \
                    "defined on the dispatch controller chain (#{controller.superclass.name} / " \
                    "ActionController / ruact plumbing) and would shadow it — rename the query method."
            end

            controller.define_method(query_method) do
              __ruact_dispatch_query(query_method)
            end
          end
        end

        # AC4 / D1 — forwards every recorded `ruact_skip_before_action` to
        # Rails' own `skip_before_action` on the generated controller. An
        # unknown callback raises here (route-draw time) unless the query
        # passed `raise: false`, mirroring stock Rails behavior.
        def apply_skips(controller, query_class)
          query_class.__ruact_skipped_callbacks.each do |callbacks, options|
            controller.skip_before_action(*callbacks, **options)
          end
        end
      end
    end
  end
end
