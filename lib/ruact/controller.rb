# frozen_string_literal: true

require "json"
require "socket"
require "uri"

module Ruact
  # Include in ApplicationController to enable RSC rendering.
  #
  #   class ApplicationController < ActionController::Base
  #     include Ruact::Controller
  #   end
  #
  # After that, any action whose view is a .html.erb file will automatically:
  # - Respond to text/x-component requests with a raw Flight payload
  # - Respond to text/html requests with an HTML shell + inline Flight payload
  module Controller
    extend ActiveSupport::Concern

    private

    # Returns the boot-time cached manifest (set by Railtie#config.to_prepare).
    # No per-request file I/O (AC#6).
    def rsc_manifest
      Ruact.manifest
    end

    # Only activate RSC rendering for HTML-like requests (AC FR26).
    # JSON, XML, and other formats bypass RSC entirely so respond_to blocks
    # and explicit render calls work without interference.
    def default_render
      if rsc_template_exists? && (request.format.html? || rsc_request?)
        rsc_render
      else
        super
      end
    end

    # Render the RSC view for the current action using ActionView's full pipeline.
    # ActionView handles layouts, partials, and helpers — the ErbPreprocessorHook
    # ensures all PascalCase tags are transformed before template compilation.
    #
    # Called automatically when no explicit render is performed and a matching
    # .html.erb template exists. Can also be called explicitly with options.
    #
    # +template+: logical template name (e.g. "posts/custom"), or nil to use
    #             the current action's default template.
    # +locals+:   hash of local variables to pass to the template.
    def rsc_render(template: nil, locals: {})
      pipeline  = RenderPipeline.new(rsc_manifest, controller_path: controller_path, logger: logger)
      streaming = rsc_request? && self.class.ancestors.include?(ActionController::Live)

      # ComponentRegistry is started before ActionView renders the template.
      # ViewHelper's __rsc_component__ registers components during rendering.
      # from_html eagerly captures the registry before the ensure block resets it.
      ComponentRegistry.start
      enumerator = begin
        opts = template ? { template: template } : { action: action_name }
        html = render_to_string(opts.merge(layout: false, locals: locals))
        pipeline.from_html(html, streaming: streaming)
      ensure
        ComponentRegistry.reset
      end

      if rsc_request?
        if streaming
          response.headers["Content-Type"]      = "text/x-component; charset=utf-8"
          response.headers["Cache-Control"]     = "no-cache"
          response.headers["X-Accel-Buffering"] = "no"
          begin
            enumerator.each { |row| response.stream.write(row) }
          ensure
            response.stream.close
          end
        else
          render plain: enumerator.to_a.join, content_type: "text/x-component"
        end
      else
        render html: rsc_html_shell(enumerator.to_a.join).html_safe, layout: false
      end
    end

    # Overrides Rails redirect_to for RSC requests: emits a Flight redirect row
    # (`0:{"redirectUrl":"...","redirectType":"push"}`) instead of a 302 response.
    # This allows the client-side router to handle the navigation without an extra
    # HTTP round-trip.  Non-RSC requests and external-origin redirects fall through
    # to the standard Rails implementation.
    def redirect_to(options = {}, response_options = {})
      return super unless rsc_request?

      url = url_for(options)

      begin
        uri = ::URI.parse(url)
        # External origin: fall back to standard 302 so the browser follows it normally.
        # Compare host, port, and scheme to avoid treating same-host-different-port as same-origin.
        if uri.host
          return super if uri.host != request.host
          return super if uri.port && uri.port != request.port
          return super if uri.scheme && uri.scheme != request.scheme
        end

        redirect_url  = uri.path.nil? || uri.path.empty? ? "/" : uri.path
        redirect_url += "?#{uri.query}"    if uri.query
        redirect_url += "##{uri.fragment}" if uri.fragment
      rescue ::URI::InvalidURIError
        return super
      end

      render plain: "0:#{JSON.generate({ 'redirectUrl' => redirect_url, 'redirectType' => 'push' })}\n",
             content_type: "text/x-component"
    end

    def rsc_request?
      request.headers["Accept"]&.include?("text/x-component") ||
        request.headers["RSC-Request"] == "1"
    end

    def rsc_template_exists?
      File.exist?(default_template_path)
    end

    def default_template_path
      action = action_name
      controller = self.class.name.underscore.sub("_controller", "")
      Rails.root.join("app", "views", controller, "#{action}.html.erb")
    end

    def rsc_html_shell(flight_payload)
      escaped_payload = flight_payload.gsub("</script>", '<\/script>')
      <<~HTML
        <!DOCTYPE html>
        <html lang="en">
          <head>
            <meta charset="UTF-8" />
            <meta name="viewport" content="width=device-width, initial-scale=1" />
            <title>Rails RSC</title>
            #{vite_tags}
          </head>
          <body>
            <div id="root"></div>
            <script>
              (function() {
                var d = (self.__FLIGHT_DATA = self.__FLIGHT_DATA || []);
                d.push(#{escaped_payload.inspect});
              })();
            </script>
          </body>
        </html>
      HTML
    end

    def vite_tags
      if Rails.env.development? && vite_dev_running?
        # @vitejs/plugin-react normally injects this preamble by processing index.html.
        # Since our HTML is generated by Rails (not Vite), we inject it manually.
        # Without it, every JSX file throws "can't detect preamble" at runtime.
        react_preamble = <<~JS
          <script type="module">
            import RefreshRuntime from 'http://localhost:5173/@react-refresh';
            RefreshRuntime.injectIntoGlobalHook(window);
            window.$RefreshReg$ = () => {};
            window.$RefreshSig$ = () => (type) => type;
            window.__vite_plugin_react_preamble_installed__ = true;
          </script>
        JS

        react_preamble + <<~HTML
          <script type="module" src="http://localhost:5173/@vite/client"></script>
          <script type="module" src="http://localhost:5173/app/javascript/application.jsx"></script>
        HTML
      else
        # Production: read hashed URL from Vite manifest
        entry = vite_manifest_entry("app/javascript/application.jsx")
        src   = entry ? "/assets/#{entry['file']}" : "/assets/application.js"
        %(<script type="module" src="#{src}"></script>)
      end
    end

    def vite_dev_running?
      require "socket"
      Socket.tcp("localhost", 5173, connect_timeout: 1).close
      true
    rescue Errno::ECONNREFUSED, Errno::EHOSTUNREACH, Errno::ETIMEDOUT, SocketError
      false
    end

    def vite_manifest_entry(src_path)
      manifest_path = Rails.root.join("public", "assets", ".vite", "manifest.json")
      return nil unless File.exist?(manifest_path)

      JSON.parse(File.read(manifest_path))[src_path]
    end
  end
end
