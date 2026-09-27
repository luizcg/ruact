# frozen_string_literal: true

module Ruact
  module Controller
    # Story 17.0i — an explicit `render` of a ruact page goes through ruact.
    #
    # `render :new, status: :unprocessable_entity`, the Rails idiom for a failed
    # save, used to answer 500 on a ruact page: Rails rendered the template on
    # its own and the first client component raised. `render` is PUBLIC, as
    # Rails has it — the `responders` gem calls `controller.render`; Rails
    # excludes its own public methods from `action_methods`, so it is not
    # routable.
    module PageRendering
      # Story 17.0i — `render :new, status: :unprocessable_entity`, the Rails idiom
      # for a failed save, on a ruact page. Rails would render the template itself,
      # outside a `ruact_render`, and the first client component in it would raise.
      # So a `render` of a ruact PAGE of this controller — the same predicate
      # `default_render` uses: `ruact_page_action?` and the template in this
      # controller's own folder — goes through `ruact_render`, with its `status:`,
      # `locals:` and `location:`, when that `.html.erb` is the template RAILS
      # would pick for this request: the format it negotiated (a `.json` path,
      # `params[:format]`, the `respond_to` branch, the Accept header) decides, so
      # a scaffold's `format.json { render :show }` still renders `show.json`.
      # Everything else is Rails' own: other renderers (`json:`, `plain:`,
      # `partial:`…, including the `render plain:` / `html:` ruact itself issues),
      # a template of another folder, an action outside `ruact_pages`. `layout:`
      # and `content_type:` do not apply: a ruact page is rendered into
      # `config.layout`, as HTML or Flight, like every ruact page.
      def render(*args, &block)
        page = block ? nil : __ruact_page_render(args)
        return super unless page

        self.location = url_for(page[:location]) if page[:location]
        # As Rails' own `assigns:` does: instance variables of the view.
        page[:assigns]&.each { |name, value| instance_variable_set(:"@#{name}", value) }
        __ruact_render(**page.slice(:template, :locals, :status, :details))
      ensure
        # The declined-option note explains THIS render only (review R4): a
        # later render in the request — a `rescue_from`'s — must not inherit it.
        if instance_variable_defined?(:@__ruact_declined_render_options)
          remove_instance_variable(:@__ruact_declined_render_options)
        end
      end

      private

      # The options of a plain template render — the only `render` ruact takes
      # over. Anything else (`json:`, `plain:`, `partial:`, a registered renderer
      # like `turbo_stream:`, an option a gem adds, like wicked_pdf's `pdf:`, or a
      # key Rails ignores, like `alert:`) means the render is not ruact's to
      # answer — Rails renders it, and the error that follows names the option
      # (Story 17.0i review R3, decision of Luiz).
      # `prefixes:` is not among them (review R4): it names the folders to look
      # in, and a page is this controller's own folder only.
      TEMPLATE_RENDER_OPTIONS = %i[action template locals status location layout content_type
                                   formats variants variant handlers locale assigns].freeze
      private_constant :TEMPLATE_RENDER_OPTIONS

      # The `ruact_render` arguments for an explicit `render` of one of this
      # controller's ruact pages, or nil. Rails' own `_normalize_args` reads the
      # arguments (`render :new` → action, `render "posts/new"` → template), on a
      # copy: it hands a Hash argument back as itself.
      def __ruact_page_render(args)
        options = _normalize_args(*args.map { |arg| arg.is_a?(Hash) ? arg.dup : arg })
        action = __ruact_render_target(options)
        return nil unless action && self.class.ruact_page_action?(action)

        page = self.class.ruact_template_path(action)
        return nil unless File.exist?(page)
        return __ruact_decline(options) unless (options.keys - TEMPLATE_RENDER_OPTIONS).empty?

        details = __ruact_render_details(options)
        return nil unless __ruact_rails_would_render?(action, details, page)

        { template: "#{controller_path}/#{action}", locals: options[:locals] || {}, status: options[:status],
          location: options[:location], assigns: options[:assigns], details: details }
      end

      # A render of a ruact page with an option ruact does not take goes to Rails.
      # When it named the page (`action:` / `template:`), the options are kept so
      # the error that follows — a client component rendered outside ruact — says
      # which ones (`Ruact::ViewHelper#__ruact_component__`). `render json:` names
      # no template: nothing to explain.
      def __ruact_decline(options)
        unknown = options.keys - TEMPLATE_RENDER_OPTIONS
        @__ruact_declined_render_options = unknown if options.key?(:action) || options.key?(:template)
        nil
      end

      # The lookup details of a render, as Rails' own render passes them: each an
      # Array, a nil ignored; `variant:` is `variants:`.
      def __ruact_render_details(options)
        details = options.slice(:formats, :variants, :handlers, :locale)
        details[:variants] = options[:variant] if options.key?(:variant) && !options.key?(:variants)
        details.compact.transform_values { |value| Array(value) }
      end

      # Whether Rails, left alone, would render `page` for `action`: the lookup
      # it does itself, with the formats it negotiated for this request (and a
      # render's own `formats:` / `variants:` / `handlers:` / `locale:`). A Flight request
      # negotiates every format, HTML first — the page; a `.json` request or a
      # `format.json` branch negotiates JSON — the JSON template, or Rails' own
      # MissingTemplate.
      def __ruact_rails_would_render?(action, details, page)
        template = lookup_context.find_template(action, [controller_path], false, [], details)
        __ruact_page_template?(template.identifier, action, page)
      rescue ActionView::MissingTemplate
        false
      end

      # The page itself, or a locale/variant of it Rails picked (`new.pt-BR.html.erb`,
      # `new.html+phone.erb`): the same folder, the same action, HTML, ERB.
      def __ruact_page_template?(identifier, action, page)
        File.identical?(File.dirname(identifier), File.dirname(page)) &&
          File.basename(identifier).match?(/\A#{Regexp.escape(action)}(\.[\w-]+)?\.html(\+[\w-]+)?\.erb\z/)
      end

      # The action whose template `options` name, when it is one of this
      # controller's: `action: "new"`, `template: "<controller_path>/new"`, or
      # nothing at all (`render status: 422` — the current action's template).
      def __ruact_render_target(options)
        if options.key?(:template)
          directory, name = File.split(options[:template].to_s)
          directory == controller_path ? name : nil
        elsif options.key?(:action)
          name = options[:action].to_s
          name.include?("/") ? nil : name
        else
          action_name
        end
      end
    end
  end
end
