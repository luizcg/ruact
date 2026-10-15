# frozen_string_literal: true

require "erb"

module Ruact
  # Story 19-3 — the page's JavaScript built by another ruact than the server's.
  #
  # The Vite plugin records which ruact built the JavaScript in
  # `react-client-manifest.json` ({ClientManifest#build_version}). When that is
  # not this gem's version — or the build records none, as every build by 0.0.21
  # and before — the browser runs another release's runtime against this
  # server, and a page that streams keeps its `<Suspense>` fallbacks forever
  # (measured with 0.0.19's: `spec/browser/deferred_suspense`, `./run skew`).
  #
  # Said loudly in development (a banner on the page, {ViewHelper}), once in
  # the log at boot in any environment ({Railtie}), and as a failure of
  # `rails ruact:doctor`'s manifest check ({Doctor}) — all with {.message}.
  #
  # The usual cause after `bundle update ruact` is not a forgotten build: the
  # `vite.config.js` that `ruact:install` wrote up to 0.0.21 imports the plugin
  # by the absolute path of the gem installed then, so the build and the dev
  # server keep using the old plugin while that version stays installed.
  # {.message} names it when it reads such an import, and the fix: the install
  # replaces that file with one that asks Bundler for the plugin (Story 19.4).
  module BuildSkew
    # The `vite.config` files Vite looks for, in its order.
    VITE_CONFIGS = %w[vite.config.js vite.config.mjs vite.config.ts vite.config.cjs vite.config.mts
                      vite.config.cts].freeze
    # A string literal naming ruact's plugin entry, as `ruact:install` writes it
    # (no template interpolation: a path built in JavaScript is not read).
    PLUGIN_IMPORT = %r{(["'`])([^"'`$\n]*vite-plugin-ruact/index\.js)\1}
    LOCK = Mutex.new
    private_constant :LOCK

    # Whether a build that recorded +build_version+ is another ruact's.
    #
    # @param build_version [String, nil] {ClientManifest#build_version}
    # @return [Boolean]
    def self.skewed?(build_version)
      build_version != Ruact::VERSION
    end

    # What happened and what to do, in one paragraph without the `[ruact]`
    # prefix.
    #
    # @param build_version [String, nil] {ClientManifest#build_version}
    # @param root [Pathname, String, nil] the app's root, where `vite.config.*` is read
    # @return [String]
    def self.message(build_version, root: default_root)
      built = build_version ? "ruact #{build_version}" : "an older ruact, one that did not record its version"
      "The page's JavaScript was built by #{built}, and this server is ruact #{Ruact::VERSION}: " \
        "pages that stream keep their <Suspense> fallbacks, and other pages may break. " \
        "#{remedy(root)}"
    end

    # {.message}'s fix only: the `vite.config` import when it names another
    # ruact's plugin, then the rebuild.
    #
    # @param root [Pathname, String, nil]
    # @return [String]
    def self.remedy(root = default_root)
      rebuild = "Rebuild the JavaScript with this ruact (npm run build, or restart bin/dev in development) " \
                "and deploy it together with the server."
      imported = foreign_plugin_import(root)
      return rebuild unless imported

      config = imported[:config]
      fix = if config == "vite.config.js"
              "run `rails generate ruact:install`, which replaces a vite.config.js it generated with one that " \
                "asks Bundler for the plugin (for one you edited, it prints the change to make)"
            else
              "load it from the gem Bundler has — `rails generate ruact:install` prints the change to make in #{config}"
            end
      "#{config} imports ruact's Vite plugin from #{imported[:path]}, another installation of ruact: " \
        "#{fix}, then: #{rebuild}"
    end

    # The message as a banner across the top of the page, in development.
    # Plain HTML with inline style, as the warning that the Vite dev server is
    # down: it cannot depend on the JavaScript that is the problem.
    #
    # @param message [String] {.message}
    # @return [String]
    def self.banner(message)
      <<~HTML
        <div role="alert" data-ruact-build-skew style="position:fixed;inset:0 0 auto 0;z-index:2147483647;padding:12px 16px;background:#7f1d1d;color:#fff;font:14px/1.4 system-ui,sans-serif">
          <strong>[ruact]</strong> #{ERB::Util.html_escape(message)}
        </div>
      HTML
    end

    # Logs {.message} once per process for each version a build recorded, so a
    # development server reloading its code does not repeat it, and keeps the
    # message: `vite.config.*` is read once per version, not on every page.
    #
    # @param build_version [String, nil]
    # @param logger [#warn, #error, nil]
    # @param level [Symbol] the logger method
    # @return [String, nil] the message, or nil when the build is this ruact's
    def self.note(build_version, logger:, level: :warn)
      return unless skewed?(build_version)

      key = build_version.to_s
      text, first = LOCK.synchronize do
        @noted ||= {}
        @noted.key?(key) ? [@noted[key], false] : [@noted[key] = message(build_version), true]
      end
      logger&.public_send(level, "[ruact] #{text}") if first
      text
    end

    # Forgets what it logged (specs).
    #
    # @api private
    def self.reset!
      LOCK.synchronize { @noted = nil }
    end

    # The first `vite.config.*` under +root+ whose ruact plugin import names a
    # file other than this gem's, or nil — none found, no such import, or the
    # import is this gem's. Read only for the message, never to decide.
    #
    # @api private
    # @return [Hash{Symbol => String}, nil] `{ config:, path: }`
    def self.foreign_plugin_import(root)
      return nil unless root

      VITE_CONFIGS.each do |name|
        config = File.join(root.to_s, name)
        next unless File.file?(config)

        match = File.binread(config).force_encoding(Encoding::UTF_8).scrub.match(PLUGIN_IMPORT)
        return nil unless match

        imported = match[2]
        resolved = imported.start_with?(".") ? File.expand_path(imported, root.to_s) : imported
        return nil if same_file?(resolved, Ruact.vite_plugin_path)

        return { config: name, path: imported }
      end
      nil
    rescue StandardError
      # Read only for the message: whatever goes wrong, the message goes
      # without the sentence.
      nil
    end

    def self.same_file?(one, other)
      real(one) == real(other)
    end

    def self.real(path)
      File.realpath(path)
    rescue SystemCallError
      File.expand_path(path)
    end

    def self.default_root
      Rails.root if defined?(Rails) && Rails.respond_to?(:root)
    end

    private_class_method :same_file?, :real, :default_root
  end
end
