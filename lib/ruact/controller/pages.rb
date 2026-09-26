# frozen_string_literal: true

module Ruact
  module Controller
    # Story 17.0g (FR116, decision D2) — a ruact "page" is a whole controller or
    # the actions it declares.
    #
    # Including `Ruact::Controller` makes every action with an `.html.erb` a
    # page; `ruact_pages only:` / `except:` narrows that. `default_render` and
    # the navigation boundary (Ruact::NavigationBoundary) both read
    # `ruact_page_action?` — one definition, so what renders through ruact and
    # what the router treats as ruact cannot disagree.
    module Pages
      extend ActiveSupport::Concern

      included do
        # Story 17.0g — the pages this controller declared with `ruact_pages`, or
        # nil (every action with a template is a page). Inherited, and
        # redeclarable by a subclass.
        class_attribute :__ruact_pages, instance_accessor: false, instance_predicate: false, default: nil
      end

      class_methods do
        # Story 17.0g (FR116) — narrow which actions of this controller are ruact
        # pages. Without it, every action with a template is one; with it, only
        # the declared actions are, and the rest render as ordinary Rails.
        #
        # An action listed in `only:` is a page even without a template of its
        # own — the way to have `ruact_render(template: "posts/show")` treated as
        # one by the navigation boundary. Names that are not actions of this
        # controller fail loudly the first time a page is looked up: a typo must
        # not quietly become "not a ruact page".
        #
        # @param only [Symbol, String, Array<Symbol, String>] the page actions
        # @param except [Symbol, String, Array<Symbol, String>] every action but these
        # @return [void]
        # @example Only `show` renders through ruact
        #   class PostsController < ApplicationController
        #     include Ruact::Controller
        #     ruact_pages only: %i[show]
        #   end
        def ruact_pages(only: nil, except: nil)
          raise ArgumentError, "ruact_pages takes exactly one of only: or except: (#{name})" if only.nil? == except.nil?

          self.__ruact_pages = { only: only && Array(only).map(&:to_s).freeze,
                                 except: except && Array(except).map(&:to_s).freeze,
                                 declared_in: self }.freeze
        end

        # Whether `action` is a page this controller renders through ruact:
        # every action unless `ruact_pages` narrowed it. Calling `ruact_pages`
        # again replaces the declaration (it does not accumulate). The navigation boundary
        # (Ruact::NavigationBoundary) and `default_render` both read this.
        #
        # @param action [String, Symbol]
        # @return [Boolean]
        # @raise [Ruact::ConfigurationError] when `ruact_pages` names an action
        #   this controller does not have
        def ruact_page_action?(action)
          declared = __ruact_pages
          return true if declared.nil?

          Pages.check_declared!(declared)
          return declared[:only].include?(action.to_s) if declared[:only]

          !declared[:except].include?(action.to_s)
        end

        # Listed in `ruact_pages only:` — a page by declaration, template or not.
        #
        # @param action [String, Symbol]
        # @return [Boolean]
        def ruact_declared_page?(action)
          Array(__ruact_pages&.dig(:only)).include?(action.to_s)
        end
      end

      # The typo check, against the class that DECLARED the pages — a base
      # controller's `ruact_pages` is not about each subclass's actions. Only
      # `only:` is checked: an `except:` naming a missing action excludes nothing
      # and harms nothing. A template-only action (no method, a view Rails
      # renders implicitly) is an action.
      #
      # @api private
      # @param declared [Hash] a `__ruact_pages` declaration
      # @return [void]
      # @raise [Ruact::ConfigurationError] when `only:` names no action of it
      def self.check_declared!(declared)
        owner = declared[:declared_in]
        names = Array(declared[:only])
        return if names.empty? || owner.nil?

        unknown = names - owner.action_methods.to_a
        unknown = unknown.reject { |action| File.exist?(owner.ruact_template_path(action)) }
        return if unknown.empty?

        what = unknown.one? ? "is not an action" : "are not actions"
        raise Ruact::ConfigurationError,
              "#{owner.name} declares ruact_pages for #{unknown.join(', ')}, which #{what} of it " \
              "(no method and no template). Check the spelling in `ruact_pages`."
      end
    end
  end
end
