# frozen_string_literal: true

module Ruact
  # Story 9.4 (route-driven redesign, Phase B) — base class for v2 server
  # QUERIES. Queries are plain classes under `app/queries/`; each public
  # instance method defined directly on the subclass is one query:
  #
  #   # app/queries/application_query.rb
  #   class ApplicationQuery < Ruact::Query; end
  #
  #   # app/queries/catalog_query.rb
  #   class CatalogQuery < ApplicationQuery
  #     def categories
  #       Category.active.pluck(:id, :name).map { |id, name| { value: id, label: name } }
  #     end
  #
  #     def my_categories
  #       current_user.categories.pluck(:id, :name)
  #     end
  #   end
  #
  #   # config/routes.rb
  #   Rails.application.routes.draw do
  #     ruact_queries CatalogQuery   # GET /q/categories, GET /q/myCategories — visible in `rails routes`
  #   end
  #
  # Per the 2026-06-02 ADR addendum (Decision 2), dispatch goes through an
  # internal gem controller that inherits `Ruact.config.query_parent_controller`
  # (default `ApplicationController`) — the host's REAL callback chain
  # (`authenticate_user!`, tenant scoping, Pundit) runs BEFORE the query class
  # is instantiated (FR89). The query instance is fresh per request (NFR8) and
  # receives its execution context via the constructor, so
  # `CatalogQuery.new(fake_context).categories` is unit-testable with no Rails
  # boot.
  #
  # The context accessors below are defined on `Ruact::Query` itself, so they
  # are INHERITED by subclasses — they never appear in a subclass's
  # `public_instance_methods(false)`, which is exactly the set the
  # `ruact_queries` routing macro mounts (one named GET route per method).
  class Query
    # @param context [#current_user, #params, #request, #session] the
    #   per-request execution context. In production this is a
    #   {Ruact::ServerFunctions::QueryContext} wrapping the dispatching
    #   controller; in unit tests any object exposing the four readers works.
    def initialize(context)
      @__ruact_context = context
    end

    # @return [Object, nil] the host's authenticated user, via the dispatching
    #   controller's own `current_user` (Devise / Pundit / hand-rolled).
    def current_user
      @__ruact_context.current_user
    end

    # @return [Object] the request params (query-string parameters on a GET).
    def params
      @__ruact_context.params
    end

    # @return [Object] the live request.
    def request
      @__ruact_context.request
    end

    # @return [Object] the host middleware's session.
    def session
      @__ruact_context.session
    end

    class << self
      # Story 9.4 AC4 / D1 — per-query callback opt-out (resolves ADR open
      # item 1). Mirrors Rails' `skip_before_action` ergonomics; the recorded
      # skips are applied verbatim to THIS query class's generated dispatch
      # controller when `ruact_queries` draws its routes, so the opt-out never
      # leaks to other query classes:
      #
      #   class PublicCatalogQuery < ApplicationQuery
      #     ruact_skip_before_action :authenticate_user!
      #
      #     def categories = Category.pluck(:id, :name)
      #   end
      #
      # Options are forwarded to `skip_before_action` untouched — `only:` /
      # `except:` scope the skip to specific query methods (each method is one
      # controller action), `raise: false` tolerates a callback the parent
      # does not define.
      #
      # @param callbacks [Array<Symbol>] callback name(s) to skip.
      # @param options [Hash] forwarded to `skip_before_action` verbatim.
      # @return [void]
      def ruact_skip_before_action(*callbacks, **options)
        __ruact_skipped_callbacks << [callbacks.map(&:to_sym), options]
        nil
      end

      # The recorded `(callbacks, options)` pairs for this query class,
      # consumed by {Ruact::ServerFunctions::QueryDispatch} when the dispatch
      # controller is generated. Per-class (not inherited) — a skip describes
      # the queries of the class that declares it.
      #
      # @return [Array<Array(Array<Symbol>, Hash)>]
      def __ruact_skipped_callbacks
        @__ruact_skipped_callbacks ||= []
      end
    end
  end
end
