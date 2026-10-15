# frozen_string_literal: true

require "securerandom"

module Ruact
  module Controller
    # Story 19-1 (ADR D6, option A) — which actions send their page as it
    # renders: the shell first, then each `<Suspense>`'s content when it is
    # ready.
    #
    # Streaming needs `ActionController::Live`, and Live is decided before the
    # action runs: it gives the action a response whose body is a queue, and
    # runs the action in a thread of its own. So the app says which actions
    # stream (`ruact_streaming`), and ruact applies Live to those and only
    # those. The other actions of the controller respond as they did — a
    # buffered response with its `ETag`, on the request's thread.
    #
    # A controller that includes `ActionController::Live` itself, and declares
    # nothing, streams every action.
    module Streaming
      extend ActiveSupport::Concern

      # Where `Controller.action(:name)` leaves the action's name: a route that
      # names no action (`get "/x", to: PagesController.action(:show)`) gives
      # `make_response!` nothing else to go on.
      ACTION_ENV = "ruact.action"

      # The thread that received the request. Under Live the action runs in
      # another one, and what that thread leased from the connection pool is
      # its own to give back.
      REQUEST_THREAD_ENV = "ruact.request_thread"

      included do
        # Story 19-1 — the actions this controller declared with
        # `ruact_streaming`, or nil. Inherited, and redeclarable by a subclass.
        class_attribute :__ruact_streaming, instance_accessor: false, instance_predicate: false, default: nil
        singleton_class.prepend(ResponseChoice)
      end

      class_methods do
        # Story 19-1 — the actions whose page is sent as it renders: the shell
        # and the `<Suspense>` fallbacks first, then each `<Suspense>`'s
        # content, rendered after the shell is sent, as it is ready. On the
        # first load and on a navigation.
        #
        # Without arguments, every ruact page of the controller streams (an
        # action with no template of its own, a JSON one, does not); `only:`
        # names the actions, `except:` leaves some out. One line in
        # `ApplicationController` makes every page of the app stream.
        #
        # The actions that stream run under `ActionController::Live`, in a
        # thread of their own: an `ETag` is not computed for them, and what a
        # middleware set up for the request's thread (a thread variable, the
        # locale) is not theirs — set it in the controller (`around_action`).
        # The other actions are untouched.
        #
        # @param only [Symbol, String, Array<Symbol, String>] the actions that stream
        # @param except [Symbol, String, Array<Symbol, String>] every page but these
        # @return [void]
        # @raise [ArgumentError] when given both `only:` and `except:`
        # @example The show page streams
        #   class PostsController < ApplicationController
        #     include Ruact::Controller
        #     ruact_streaming only: :show
        #   end
        def ruact_streaming(only: nil, except: nil)
          raise ArgumentError, "ruact_streaming takes only: or except:, not both (#{name})" if only && except

          Streaming.include_live(self)
          # Directly above Live, so the actions that do not stream skip it.
          include LiveChoice unless include?(LiveChoice)
          # Ahead of Live's `make_response!`, which this class now extends and
          # which would otherwise answer before the choice the parent has.
          singleton_class.prepend(ResponseChoice)
          self.__ruact_streaming = { only: only && Array(only).map(&:to_s).freeze,
                                     except: except && Array(except).map(&:to_s).freeze,
                                     declared_in: self }.freeze
        end

        # Whether `action` sends its page as it renders: an action declared
        # with `ruact_streaming`, or any action of a controller that includes
        # `ActionController::Live` and declares nothing.
        #
        # @param action [String, Symbol]
        # @return [Boolean]
        # @raise [Ruact::ConfigurationError] when `ruact_streaming only:` names
        #   an action this controller does not have
        def ruact_streaming?(action)
          declared = __ruact_streaming
          return include?(ActionController::Live) if declared.nil?

          name = action.to_s
          if declared[:only]
            Streaming.check_declared!(self, declared) if declared[:declared_in].equal?(self)
            return declared[:only].include?(name)
          end
          return false if declared[:except]&.include?(name)

          ruact_page?(name)
        end

        # Whether `action` runs under `ActionController::Live`: it streams a
        # ruact page, or the app included Live itself — in this controller or
        # in a parent — for actions of its own (an SSE stream, `send_stream`),
        # which keep it.
        #
        # @api private
        # @param action [String, Symbol]
        # @return [Boolean]
        def __ruact_live?(action)
          ruact_streaming?(action) || Streaming.live_by_app?(self)
        end
      end

      # Story 19-2 (AC20) — said once per process, in every environment: an
      # action declared with `ruact_streaming` got a request over HTTP/1.0, so
      # Live gave it an ordinary response and the page was sent whole. nginx
      # talks HTTP/1.0 to its upstream unless told otherwise, so in production
      # this is a proxy's configuration, found here or not at all.
      UNSTREAMED = "%<action>s streams (ruact_streaming or ActionController::Live), but the request came " \
                   "over HTTP/1.0, so the page was sent whole, not streamed. Behind nginx, set " \
                   "`proxy_http_version 1.1;` where it proxies to the app. (Rack::Test, in request " \
                   "specs, speaks HTTP/1.0 too.) (Said once.)"

      # Logs {UNSTREAMED} the first time an action that streams could not.
      #
      # @api private
      # @param controller [ActionController::Metal]
      # @return [void]
      def self.note_unstreamed(controller)
        return if @unstreamed_noted

        @unstreamed_noted = true
        action = "#{controller.class.name}##{controller.action_name}"
        controller.logger&.warn("[ruact] #{format(UNSTREAMED, action: action)}")
        nil
      end

      # Forgets that it logged (specs).
      #
      # @api private
      def self.reset_unstreamed_note!
        @unstreamed_noted = false
      end

      # Story 19-2 (AC19.3) — Rack 2's `Rack::ETag` digests a 200 body unless
      # the response has an `ETag` or a `Last-Modified`, reading it whole first
      # (`Cache-Control: no-cache` does not stop it): a page that streams was
      # held until its last `<Suspense>`. Measured with Rack 2.2.24. A weak ETag
      # of its own, new for every response, so that no `If-None-Match` ever
      # matches it. Rack 3 leaves a body it cannot hold in memory alone.
      RACK_ETAG_BUFFERS = Gem::Version.new(::Rack.release) < Gem::Version.new("3")

      # Sets that ETag on +headers+ when the app runs on Rack 2 — unless the
      # action set its own validator (`fresh_when`), which already keeps
      # `Rack::ETag` away and which conditional GET needs.
      #
      # @api private
      # @param headers [Hash, ActionDispatch::Response::Headers]
      # @return [void]
      def self.keep_unbuffered(headers)
        return unless RACK_ETAG_BUFFERS
        return if headers.key?("ETag") || headers.key?("Last-Modified")

        headers["ETag"] = %(W/"ruact-stream-#{SecureRandom.hex(8)}")
        nil
      end

      # Includes `ActionController::Live` in +controller+ for `ruact_streaming`,
      # marked as ruact's doing so {LiveInclusion} does not take it for the app's.
      #
      # @api private
      def self.include_live(controller)
        return if controller.include?(ActionController::Live)

        controller.instance_variable_set(:@__ruact_including_live, true)
        controller.include(ActionController::Live)
      ensure
        controller.remove_instance_variable(:@__ruact_including_live) if
          controller.instance_variable_defined?(:@__ruact_including_live)
      end

      # Whether the app included `ActionController::Live` in +controller+ or a
      # parent, itself and not through `ruact_streaming` (see {LiveInclusion}).
      #
      # @api private
      def self.live_by_app?(controller)
        controller.ancestors.any? { |ancestor| ancestor.instance_variable_get(:@__ruact_live_by_app) }
      end

      # Notes, on a class, that the app included `ActionController::Live` in it
      # itself. Ruby calls `append_features` on every `include`, even of a
      # module the class already has — the case of a controller that includes
      # Live under a parent that declared `ruact_streaming`, where the include
      # changes nothing and has to be seen anyway.
      module LiveInclusion
        def append_features(base)
          unless base.instance_variable_defined?(:@__ruact_including_live)
            base.instance_variable_set(:@__ruact_live_by_app, true)
          end
          super
        end
      end
      ActionController::Live.singleton_class.prepend(LiveInclusion)

      # The typo check for `ruact_streaming only:`, as `ruact_pages` has it
      # (see {Pages.check_declared!}).
      #
      # @api private
      # @raise [Ruact::ConfigurationError]
      def self.check_declared!(owner, declared)
        unknown = declared[:only] - owner.action_methods.to_a
        unknown = unknown.reject { |action| File.exist?(owner.ruact_template_path(action)) }
        return if unknown.empty?

        what = unknown.one? ? "is not an action" : "are not actions"
        raise Ruact::ConfigurationError,
              "#{owner.name} declares ruact_streaming for #{unknown.join(', ')}, which #{what} of it " \
              "(no method and no template). Check the spelling in `ruact_streaming`."
      end

      # `process` for an action that does not stream, in a controller that
      # includes Live: everything but Live's own `process`, which would run the
      # action in another thread.
      #
      # @api private
      def self.process_without_live(controller, name)
        method = controller.method(:process)
        method = method.super_method until method.owner == ActionController::Live
        method.super_method.call(name)
      end

      # The response, chosen per action: Live's for an action that streams, the
      # ordinary one for the rest. Prepended to every ruact controller's
      # singleton class.
      module ResponseChoice
        def make_response!(request)
          request.set_header(REQUEST_THREAD_ENV, Thread.current)
          return super unless __ruact_streaming

          name = request.get_header(ACTION_ENV) || request.path_parameters[:action]
          return super if name.nil? || __ruact_live?(name)

          ActionController::Metal.singleton_class.instance_method(:make_response!).bind_call(self, request)
        end

        # The app `Controller.action(:name)` returns, which tells
        # `make_response!` the action's name on the way in.
        def action(name)
          app = super
          action_name = name.to_s.freeze
          lambda do |env|
            env[ACTION_ENV] = action_name
            app.call(env)
          end
        end
      end

      # Included right after Live by `ruact_streaming`: an action that does not
      # stream runs on the request's thread, as without Live — unless the app
      # included Live itself, for actions of its own.
      module LiveChoice
        def process(name)
          return super if self.class.__ruact_live?(name)

          Streaming.process_without_live(self, name)
        end
      end

      private

      # Story 19-1 (D4) — under Live the action ran in a thread of the pool, and
      # Rails gives back what the request's thread leased, not what this one
      # did. Without this a `Model.connection` in a streamed action keeps its
      # connection until the thread is reused (measured in 19-0, in 0.0.19
      # too). Not when the action ran on the request's thread (Rails' test
      # support runs Live inline).
      def process_action(*)
        super
      rescue StandardError => e
        # Story 19-2 (AC6) — raised once the page was sent (an `after_action`):
        # Live only logs what is raised after the response started, so the
        # app's error reporting would never hear of it.
        if @__ruact_streamed && defined?(Rails) && Rails.respond_to?(:error)
          Rails.error.report(e, handled: false, severity: :error, source: "ruact.stream")
        end
        raise
      ensure
        __ruact_check_writes_after_stream
        __ruact_release_connections if __ruact_on_live_thread?
      end

      def __ruact_on_live_thread?
        request_thread = request&.get_header(REQUEST_THREAD_ENV)
        !request_thread.nil? && !request_thread.equal?(Thread.current)
      end

      def __ruact_release_connections
        return unless defined?(::ActiveRecord::Base)

        ::ActiveRecord::Base.connection_handler.clear_active_connections!(:all)
      end
    end
  end
end
