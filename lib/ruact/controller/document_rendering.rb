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
      # A layout that never calls `ruact_js_assets` would emit a document with no
      # bootstrap entry and no Flight payload — a blank page — so the rendered
      # document is checked before it is committed:
      #
      # - under `:auto` (the default) an unready or absent layout is the expected
      #   not-yet-migrated state: fall back to the shell, and say so in dev.
      # - under an EXPLICIT `true`/String the developer asked for the layout path,
      #   so an unready layout is a configuration error: raise in dev/test, and in
      #   production log it and degrade to the shell rather than serve a blank
      #   page to real traffic.
      def render_ruact_document(payload)
        layout = Ruact.config.layout
        return render html: ruact_html_shell(payload).html_safe, layout: false if layout == false

        unless ruact_layout_resolvable?(layout)
          __ruact_handle_unready_layout(layout, :missing)
          return render html: ruact_html_shell(payload).html_safe, layout: false
        end

        # Copied to the view by Rails' `view_assigns` plumbing (the name does not
        # match the `/\A@_/` protected-ivar filter) — that is how the layout's
        # zero-argument `ruact_js_assets` reaches THIS render's Flight payload.
        @ruact_flight_payload = payload
        document = render_to_string(html: "".html_safe, layout: layout == :auto ? true : layout)

        if document.include?(RUACT_ASSETS_MARKER)
          render html: document.html_safe, layout: false
        else
          __ruact_handle_unready_layout(layout, :unwired)
          render html: ruact_html_shell(payload).html_safe, layout: false
        end
      ensure
        remove_instance_variable(:@ruact_flight_payload) if instance_variable_defined?(:@ruact_flight_payload)
      end

      # Is there a layout to render into at all? Asking FIRST matters: passing
      # `layout: true` to a controller with no resolvable layout raises
      # `ArgumentError("There was no default layout for ...")`, which would turn
      # every page of an API-shaped or `layout false` app into a 500 the moment
      # this default landed. `_default_layout`'s `require_layout` argument
      # defaults to false precisely so it can be used as a probe — it returns nil
      # instead of raising. `action_has_layout?` is honored inside it, so a
      # controller that declared `layout false` correctly reports "no layout" and
      # keeps ruact's built-in shell.
      #
      # A String-NAMED layout is probed through the lookup context instead, so a
      # typo'd or undeployed layout name degrades the same way rather than
      # raising `MissingTemplate` on live traffic.
      def ruact_layout_resolvable?(layout)
        if layout.is_a?(String)
          lookup_context.exists?(layout, ["layouts"])
        else
          !_default_layout(lookup_context, [:html], []).nil?
        end
      rescue StandardError
        # Rails' layout-resolution internals are not public API. If they ever
        # move, degrade to the built-in shell (visible in dev and in
        # `rails ruact:doctor`) rather than take the whole app down.
        false
      end

      def __ruact_handle_unready_layout(layout, reason)
        detail =
          if reason == :missing
            "no layout could be resolved for it"
          else
            "the layout it rendered never called `ruact_js_assets`, so the document " \
              "carried no React bootstrap and no Flight payload (a blank page)"
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
