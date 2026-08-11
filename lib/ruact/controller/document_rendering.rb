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

      # What counts as a mount target and what counts as a real call both live in
      # {Ruact::LayoutSource}, shared with `ruact:install` so the runtime and the
      # generator can never disagree about whether a layout is migrated.

      private

      # Emit the full HTML document a browser gets on a normal navigation.
      #
      # `Ruact.config.layout` decides, and it is EXPLICIT — ruact does not try
      # to infer whether your layout is ready. It used to: three review rounds
      # each found another template shape that fooled the inference (a mention
      # in a comment, a commented-out call, a trim-mode comment), and each wrong
      # answer governed how every page in the app rendered. Answering "does this
      # template call this method?" is not something pattern-matching can do
      # reliably, so the question is no longer asked. See
      # Ruact::Configuration#layout.
      #
      # - `false` (the default) → the built-in shell. Byte-identical to ruact's
      #   behaviour before the layout path existed, with no detection in the
      #   way, so an app that has not opted in cannot be affected by any of this.
      # - `true` / a String → render through the app's layout. `ruact:install`
      #   writes both halves of that opt-in together: `config.layout = true` in
      #   the initializer AND `<%= ruact_js_assets %>` in the layout.
      #
      # An opted-in layout that does not actually emit the assets would produce
      # a blank page, so the rendered document is checked before it is
      # committed: that is a configuration error, raised in development/test and
      # logged-and-degraded in production rather than served to real traffic.
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
        document = render_to_string(html: "".html_safe, layout: layout)

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
      def ruact_document_mountable?(document)
        document.include?(RUACT_ASSETS_MARKER) && Ruact::LayoutSource.root?(document)
      end

      # Is there a layout to render into at all? Asking FIRST matters: passing
      # `layout: true` to a controller with no resolvable layout raises
      # `ArgumentError("There was no default layout for ...")`, which would turn
      # every page of an API-shaped or `layout false` controller into a 500 in
      # an app that opted in globally. `_default_layout`'s `require_layout`
      # argument defaults to false precisely so it can be used as a probe — it
      # returns nil instead of raising, and honours `action_has_layout?`.
      #
      # `NameError` is deliberately NOT swallowed: `_default_layout` re-raises it
      # as "Could not render layout: ..." to surface a broken layout resolver
      # (`layout -> { MissingConstant::LAYOUT }`). Turning that into "no layout"
      # would hide the developer's bug behind a silently degraded page.
      def ruact_layout_resolvable?(layout)
        return ruact_layout_exists?(layout) if layout.is_a?(String)

        resolved = _default_layout(lookup_context, [:html], [])
        return false if resolved.nil? || resolved == false
        # `_default_layout` returns a Template for the conventional lookup but a
        # bare String path for a controller-declared `layout "name"` — and it
        # returns that String WITHOUT checking the template exists. Treating
        # "not nil" as resolvable therefore sent a declared-but-missing layout
        # into `render_to_string`, where it raised `MissingTemplate` instead of
        # taking the intended degrade-to-shell path.
        return ruact_layout_exists?(resolved) if resolved.is_a?(String)

        true
      rescue NameError
        raise
      rescue StandardError
        false
      end

      def ruact_layout_exists?(name)
        lookup_context.exists?(name.to_s.delete_prefix("layouts/"), ["layouts"])
      end

      def __ruact_handle_unready_layout(_layout, reason)
        detail =
          if reason == :missing
            "no layout could be resolved for it"
          else
            "the layout it rendered emitted no `ruact_js_assets` output (or no " \
              "`<div id=\"root\"></div>` to mount into), which would have been a blank page"
          end

        message = <<~MSG.strip
          ruact: #{controller_path}##{action_name} fell back to ruact's built-in HTML shell — #{detail}.
            `Ruact.config.layout` is set, so this is a configuration error, not a default:
            the built-in shell has no stylesheet slot, so your app's CSS does not reach this page.
            Add `<%= ruact_js_assets %>` next to the `<div id="root"></div>` in your layout
            (`rails generate ruact:install` writes both; `rails ruact:doctor` reports what is missing),
            or set `Ruact.configure { |c| c.layout = false }` to use the built-in shell deliberately.
        MSG

        # A MISSING layout is a legitimate per-controller choice — an API-shaped
        # controller, or one that declared `layout false`, inside an app that
        # opted in globally. Raising there would break a normal Rails pattern,
        # so it degrades to the shell and says so where a developer will see it.
        #
        # An UNWIRED layout is different: the developer pointed ruact at a
        # layout that cannot mount the app, which is their bug to see — loudly
        # in development, and degraded (never blank) in production.
        if reason == :missing
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
