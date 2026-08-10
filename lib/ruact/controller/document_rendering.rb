# frozen_string_literal: true

module Ruact
  module Controller
    # How a ruact response becomes a full HTML DOCUMENT — the wrapper a browser
    # gets on a normal navigation, as opposed to the raw `text/x-component`
    # Flight body an in-app navigation gets.
    #
    # Split out of `Ruact::Controller` because it answers one self-contained
    # question ("who owns the `<head>`?") whose answer is load-bearing: the host
    # app's layout does, because `stylesheet_link_tag`, favicons, fonts,
    # analytics and every `<head>`-writing gem live there. `#ruact_html_shell`
    # is the fallback for an app whose layout has not been migrated — it is
    # deliberately minimal and has NO stylesheet slot.
    module DocumentRendering
      extend ActiveSupport::Concern

      # Proof that a host layout called `ruact_js_assets`: the helper always
      # emits the `__FLIGHT_DATA` bootstrap script when a payload is present,
      # and `render_ruact_document` always supplies one. Matching on the payload
      # script (rather than on the entry `<script src>`) keeps the check true in
      # BOTH dev and production, whose entry tags differ.
      RUACT_ASSETS_MARKER = "__FLIGHT_DATA"

      # The React mount target. Matched loosely on purpose — a host layout may
      # write the div with single quotes, extra attributes, or a different
      # attribute order, and all of those mount fine.
      RUACT_ROOT_MARKER = /id\s*=\s*["']root["']/

      # An ERB OUTPUT tag that calls the helper — `<%= ruact_js_assets %>`, with
      # or without arguments. Matching the bare name would count a mention in a
      # comment (`<%# ... ruact_js_assets ... %>`) or a commented-out call as
      # wired, and ruact would then render a layout that emits nothing.
      RUACT_ASSETS_CALL = /<%=[^%]*\bruact_js_assets\b/

      private

      # Emit the full HTML document a browser gets on a normal navigation.
      #
      # The document `<head>` belongs to the HOST APP — `stylesheet_link_tag`,
      # favicons, fonts, analytics and every `<head>`-writing gem only reach the
      # page when Rails' own layout owns the document. So this renders through
      # that layout, with the React root's bootstrap tags supplied by the layout's
      # `<%= ruact_js_assets %>` call. `#ruact_html_shell` stays as the fallback
      # for an app whose layout has not been migrated; it is deliberately minimal
      # and has NO stylesheet slot, so a page rendered through it carries no app
      # CSS at all.
      #
      # Strategy comes from `Ruact.config.layout` (see Ruact::Configuration#layout).
      #
      # Under `:auto` the layout is INSPECTED, never speculatively executed. That
      # distinction is the whole backward-compatibility guarantee, and getting it
      # wrong is subtle: on a pre-migration app the layout has NEVER run on a
      # ruact page, so it may reference state a ruact action never sets (a
      # `@page_title` ivar, a `content_for` the view was expected to fill).
      # Rendering it just to discover it lacks `ruact_js_assets` would run that
      # code for the first time and could raise — turning a working page into a
      # 500 the moment this default landed, on an app that changed nothing. So
      # `:auto` reads the layout's SOURCE and only renders through it once the
      # helper is actually there.
      #
      # Under an EXPLICIT `true`/String the developer opted in, so the layout IS
      # rendered and the resulting document is checked instead; an unready layout
      # is then a configuration error (raised in dev/test, logged and degraded in
      # production rather than serving a blank page to real traffic).
      def render_ruact_document(payload)
        layout = Ruact.config.layout
        return render html: ruact_html_shell(payload).html_safe, layout: false if layout == false

        readiness = ruact_layout_readiness(layout)
        unless readiness == :ready
          __ruact_handle_unready_layout(layout, readiness)
          return render html: ruact_html_shell(payload).html_safe, layout: false
        end

        # Copied to the view by Rails' `view_assigns` plumbing (the name does not
        # match the `/\A@_/` protected-ivar filter) — that is how the layout's
        # zero-argument `ruact_js_assets` reaches THIS render's Flight payload.
        @ruact_flight_payload = payload
        document = render_to_string(html: "".html_safe, layout: layout == :auto ? true : layout)

        if ruact_document_mountable?(document)
          render html: document.html_safe, layout: false
        else
          __ruact_handle_unready_layout(layout, :unwired)
          render html: ruact_html_shell(payload).html_safe, layout: false
        end
      ensure
        remove_instance_variable(:@ruact_flight_payload) if instance_variable_defined?(:@ruact_flight_payload)
      end

      # A document is only usable if BOTH halves are present: the payload/bootstrap
      # block AND something to mount into. Checking the assets alone accepts a
      # layout that calls `ruact_js_assets` in `<head>` but never got the root div
      # — React then boots with no mount target and the page is silently blank.
      # Requiring both also makes an accidental `__FLIGHT_DATA` string in user
      # content far less likely to read as a wired layout.
      def ruact_document_mountable?(document)
        document.include?(RUACT_ASSETS_MARKER) && document.match?(RUACT_ROOT_MARKER)
      end

      # `:missing` (no layout to render into), `:unwired` (a layout that does not
      # call `ruact_js_assets`) or `:ready`.
      #
      # Resolving FIRST matters even before the source check: passing
      # `layout: true` to a controller with no resolvable layout raises
      # `ArgumentError("There was no default layout for ...")`, which would turn
      # every page of an API-shaped or `layout false` app into a 500 the moment
      # this default landed. `_default_layout`'s `require_layout` argument
      # defaults to false precisely so it can be used as a probe — it returns nil
      # instead of raising. `action_has_layout?` is honored inside it, so a
      # controller that declared `layout false` correctly reports "no layout".
      #
      # A String-NAMED layout is looked up by name instead, so a typo'd or
      # undeployed layout degrades the same way rather than raising
      # `MissingTemplate` on live traffic.
      def ruact_layout_readiness(layout)
        template = ruact_layout_template(layout)
        return :missing if template.nil?
        # An explicit opt-in is taken at its word — the developer asked for this
        # layout, so it is rendered and judged by its OUTPUT (which also covers a
        # layout that reaches the helper through a partial, invisible to a source
        # read). Only `:auto` has to be conservative, because it speaks for apps
        # that never asked for anything.
        return :ready unless layout == :auto

        ruact_layout_source_wired?(template) ? :ready : :unwired
      end

      # The layout template WITHOUT rendering it. Returns nil when there is none.
      #
      # `NameError` is deliberately NOT swallowed: `_default_layout` re-raises it
      # as "Could not render layout: ..." precisely to surface a broken layout
      # resolver (`layout -> { MissingConstant::LAYOUT }`). Turning that into
      # "no layout" would hide the developer's bug behind a silently degraded
      # page. Other StandardErrors degrade to the built-in shell, because Rails'
      # layout internals are not public API and a future rename should cost CSS,
      # not the whole app.
      def ruact_layout_template(layout)
        resolved = layout.is_a?(String) ? layout : _default_layout(lookup_context, [:html], [])
        ruact_resolve_layout_template(resolved)
      rescue NameError
        raise
      rescue StandardError
        nil
      end

      # `_default_layout` returns EITHER an `ActionView::Template` (conventional
      # per-controller lookup) OR a String path like `"layouts/application"`
      # (when the controller declared `layout "name"`, which `_normalize_layout`
      # only prefixes). Treating the String case as "no template" silently sent
      # every controller with a declared layout down the fallback path.
      def ruact_resolve_layout_template(resolved)
        return nil if resolved.nil? || resolved == false
        return resolved if resolved.respond_to?(:source)
        return nil unless resolved.is_a?(String)

        name = resolved.delete_prefix("layouts/")
        prefixes = ["layouts"]
        lookup_context.exists?(name, prefixes) ? lookup_context.find_template(name, prefixes) : nil
      end

      # Read the layout's SOURCE for the helper call. Deliberately a source read
      # and not a render: see `render_ruact_document`.
      #
      # KNOWN GAP, and it fails safe: a layout that reaches `ruact_js_assets`
      # only through a partial reads as unwired under `:auto`, so the app keeps
      # ruact's shell (a working page, minus its CSS) and `rails ruact:doctor`
      # reports it. Setting `Ruact.config.layout = true` opts such an app in,
      # and the output check then confirms it.
      def ruact_layout_source_wired?(template)
        return false unless template.respond_to?(:source)

        template.source.to_s.match?(RUACT_ASSETS_CALL)
      rescue StandardError
        false
      end

      def __ruact_handle_unready_layout(layout, reason)
        detail =
          if reason == :missing
            "no layout could be resolved for it"
          else
            "its layout does not call `ruact_js_assets`, so the document would carry " \
              "no React bootstrap and no mount target (a blank page)"
          end

        message = <<~MSG.strip
          ruact: #{controller_path}##{action_name} fell back to ruact's built-in HTML shell — #{detail}.
            The built-in shell has no stylesheet slot, so your app's CSS does not reach this page.
            Add `<%= ruact_js_assets %>` next to the `<div id="root"></div>` in your layout
            (`rails generate ruact:install` writes it; `rails ruact:doctor` reports it),
            or set `Ruact.configure { |c| c.layout = false }` to keep the built-in shell deliberately.
        MSG

        if layout == :auto
          # The documented, migration-safe default: an un-migrated layout is not
          # an error, it is the state every pre-existing app starts in. Say it
          # once where a developer will see it; stay silent in production.
          logger&.info(message) if __ruact_local_env?
          return
        end

        raise Ruact::Error, message if __ruact_local_env?

        logger&.error(message)
      end

      def __ruact_local_env?
        Rails.env.development? || Rails.env.test?
      rescue StandardError
        false
      end

      def ruact_html_shell(flight_payload)
        # Story 14.2 — the JS asset block (entry `<script>` tags + `__FLIGHT_DATA`)
        # is delegated to the single `Ruact::ViewHelper#ruact_js_assets`
        # implementation. The bootstrap entry script is a deferred ES module, so it
        # runs after the inline `__FLIGHT_DATA` classic script has populated the
        # queue regardless of source order — emitting the whole block in `<body>`
        # is correct.
        <<~HTML
          <!DOCTYPE html>
          <html lang="en">
            <head>
              <meta charset="UTF-8" />
              <meta name="viewport" content="width=device-width, initial-scale=1" />
              #{ruact_csrf_meta_tag}
              <title>Rails RSC</title>
            </head>
            <body>
              <div id="root"></div>
              #{ruact_js_assets(flight_payload)}
            </body>
          </html>
        HTML
      end

      # Story 8.3 review R7 — emits `<meta name="csrf-token" content="...">`
      # into the shell so the JS runtime's `<meta>` lookup can forward a
      # valid `X-CSRF-Token` on every server-function (mutation) call. Without
      # this, hosts that route `ruact_render` through the gem's HTML shell (the
      # standard path) have no token in the document and the host's
      # `protect_from_forgery` rejects every non-GET server function.
      #
      # Returns an empty string when CSRF protection isn't available
      # (non-Rails specs, or hosts that have deliberately stripped
      # `form_authenticity_token` from the controller surface).
      def ruact_csrf_meta_tag
        return "" unless respond_to?(:form_authenticity_token, true)

        token = form_authenticity_token
        return "" if token.nil? || token.empty?

        %(<meta name="csrf-token" content="#{ERB::Util.html_escape(token)}" />)
      rescue StandardError
        ""
      end
    end
  end
end
