# frozen_string_literal: true

require "json"
require "socket"
require "pathname"

module Ruact
  # Runs a suite of installation health checks and prints ✓/✗ per check.
  # Extracted from the ruact:doctor Rake task for direct testability (FR27).
  class Doctor # rubocop:disable Metrics/ClassLength
    CHECKS = %i[manifest vite controller layout head_assets streaming legacy_constant serialize_only
                flight_middleware].freeze
    # Built via Array#join so the gem-CI `name-propagation` guard does not
    # match these literals against itself (Story 5.1 review F4 — the doctor
    # file participates in the guard with no exclusion).
    LEGACY_CONST = %w[Rails Rsc].join
    LEGACY_GEM   = %w[rails rsc].join("_")
    LEGACY_CONSTANT_RE = /(?<![A-Za-z_])(?:#{LEGACY_CONST}|#{LEGACY_GEM})(?![A-Za-z_])/
    LEGACY_SCAN_GLOBS = ["config/initializers/**/*.rb", "app/**/*.rb"].freeze
    RENAME_DOC_URL = "https://github.com/luizcg/ruact/blob/main/CHANGELOG.md#renamed"

    # --- Story 13.1: serialize-only invariant tripwire (FR97) ---------------
    #
    # ruact EMITS React Flight (`text/x-component`) but must never DESERIALIZE
    # externally-supplied Flight into live Ruby objects — that keeps it outside
    # the React2Shell / CVE-2025-55182 class (a Flight-deserialization RCE). See
    # the ADR addendum in docs/internal/decisions/server-functions-api.md.
    #
    # The signal literals are assembled from fragments via Array#join so this
    # file does NOT itself contain the matched strings (mirrors the LEGACY_CONST
    # F4 lesson). `doctor.rb` is also excluded from the scan as defense in depth.
    # Only structural inbound-deserialization signals are used; the raw
    # `text/x-component` token is deliberately NOT a signal because the gem
    # legitimately EMITS that media type (controller.rb / server.rb) — matching
    # it would false-fail the current, invariant-holding tree.
    DESERIALIZE_SIGNALS = [
      # a `Deserializer` constant reference (FlightDeserializer, Flight::Deserializer, …);
      # matched as a substring so both the joined and namespaced forms trip it
      /#{%w[Deser ializer].join}/,
      # methods that turn inbound Flight into Ruby objects
      /\b#{%w[deserialize flight].join('_')}\b/,
      /\b#{%w[from flight].join('_')}\b/,
      /\b#{%w[parse flight].join('_')}\b/,
      /\b#{%w[decode flight].join('_')}\b/,
      # React Flight reader entry points invoked from Ruby (NOT createFromFlightPayload,
      # which is the client/browser deserializing the server's own trusted payload)
      /\b#{%w[create From].join}(?:NodeStream|ReadableStream|Fetch)\b/
    ].freeze
    DESERIALIZE_SIGNAL_RE = Regexp.union(DESERIALIZE_SIGNALS)
    # A line carrying this annotation is a deliberate, reviewed deserializer and
    # is treated as guarded (the check is a guard, not a blanket ban).
    ALLOW_FLIGHT_DESERIALIZATION = ["# ruact:allow", "flight", "deserialization"].join("-")
    # Exclude THIS file by its exact path (not basename) — its comments contain
    # the literal `Deserializer` example, so it must not match its own scan; but
    # a differently-located future file also named `doctor.rb` must still be
    # scanned (review finding R1 — basename exclusion was too broad).
    DOCTOR_FILE = File.expand_path(__FILE__)
    SERIALIZE_ONLY_DOC = "docs/internal/decisions/server-functions-api.md (serialize-only invariant, FR97)"

    # Response-transforming middleware that can mutate/recompress a streamed
    # `text/x-component` Flight body and break the wire contract (React-on-Rails
    # ops lesson). Matched by class name so the check needs no hard dependency.
    RESPONSE_TRANSFORMING_MIDDLEWARE = %w[Rack::Deflater].freeze

    # Statuses that do NOT fail the run. Anything else (including a malformed /
    # future status) is treated as a failure (review finding R1).
    SUCCESS_STATUSES = %i[pass warn].freeze

    # Story 15.3 (FR107) — version of the machine-readable `ruact:doctor --json`
    # document (see {#as_json}). This is an **EXPERIMENTAL / UNSTABLE** contract:
    # `0` signals the shape may change without a major version bump while the
    # agent-facing introspection surface is iterated. Gate any parser on it.
    # Distinct from {Ruact::ServerFunctions::Snapshot::VERSION_V2} (the internal
    # codegen bridge version) — do not conflate the two.
    SCHEMA_VERSION = 0

    # @param serialize_only_root [String] directory whose `**/*.rb` is scanned
    #   for the serialize-only tripwire. Defaults to the gem's own `lib/`;
    #   injectable so specs can point it at a fixture tree.
    def initialize(serialize_only_root: File.join(Ruact.gem_path, "lib"))
      @serialize_only_root = serialize_only_root
    end

    # Runs all checks, prints results, returns true if none FAIL.
    def self.run
      new.run
    end

    def run
      puts "[ruact] Health check"
      computed = results
      computed.each { |status, message| puts format_result(status, message) }
      # A :warn must NOT fail the run (Story 13.1 AC3); only :pass / :warn are
      # success. An unexpected status (rendered `✗`) fails loudly rather than
      # being silently treated as a pass (review finding R1).
      passed = passed?(computed)
      puts "Run rails ruact:doctor -- --json for how to fix each failure" unless passed
      passed
    end

    # Runs every check ONCE and returns the raw result tuples, index-aligned with
    # {CHECKS}. Each tuple is `[status, message]` or `[status, message,
    # remediation]` (the optional 3rd element is a machine-readable fix string,
    # nil when the check has no cleanly separable remediation). Shared by {#run}
    # (human path) and {#as_json} (JSON path) so a check like `check_vite` — which
    # opens a socket — never runs twice. (Story 15.3)
    #
    # @return [Array<Array>] one tuple per check, in {CHECKS} order.
    def results
      CHECKS.map { |check| send(:"check_#{check}") }
    end

    # @param computed [Array<Array>] result tuples (defaults to a fresh {#results} run).
    # @return [Boolean] true when NO check failed — only `:pass`/`:warn` are
    #   success (mirrors {#run}'s rule; an unexpected status fails).
    def passed?(computed = results)
      computed.all? { |status, _| SUCCESS_STATUSES.include?(status) }
    end

    # Story 15.3 (FR107) — the machine-readable `ruact:doctor --json` document.
    # Reuses the SAME {#results} tuples the human path prints (no double-run), so
    # the JSON never disagrees with the `✓/⚠/✗` output. EXPERIMENTAL shape — gate
    # parsers on `schema_version` (see {SCHEMA_VERSION}). Emits NO prose — the
    # rake task prints ONLY this document in JSON mode.
    #
    # @return [Hash] `{ "schema_version" => Integer, "status" =>
    #   "pass"|"fail", "checks" => [{ "name" =>, "status" =>, "message" =>,
    #   "remediation" => (String|nil) }] }`.
    def as_json
      computed = results
      {
        "schema_version" => SCHEMA_VERSION,
        "status" => passed?(computed) ? "pass" : "fail",
        "checks" => CHECKS.each_index.map do |i|
          status, message, remediation = computed[i]
          {
            "name" => CHECKS[i].to_s,
            "status" => status.to_s,
            "message" => message,
            "remediation" => remediation
          }
        end
      }
    end

    private

    def check_manifest
      path = manifest_path
      if Pathname(path).exist?
        [:pass, "Manifest found at #{path}"]
      else
        [:fail, "Manifest not found — run vite build",
         "Run vite build (or bin/dev) to generate the client manifest."]
      end
    end

    def check_vite
      TCPSocket.new("localhost", 5173).close
      [:pass, "Vite accessible at localhost:5173"]
    rescue Errno::ECONNREFUSED, Errno::EHOSTUNREACH
      [:fail, "Vite not accessible at localhost:5173 — run npm run dev",
       "Run npm run dev (or bin/dev) to start the Vite dev server."]
    end

    # Story 17.0g (FR116) — reports the ADOPTION MODE instead of demanding one.
    #
    # Whole-app (`ruact:install --app`): ApplicationController includes the
    # concern, and every action with a template renders through ruact — the
    # message says how many templates that is, which is the cost `--app` hides.
    # Island (the install default): the concern is on the controllers that
    # render ruact pages. It used to FAIL every island app, because it only
    # looked at ApplicationController. With none yet, a warning: the install
    # worked; there is simply no page.
    #
    # Mechanical, like the layout checks: it reads files, it never renders.
    def check_controller
      application = Rails.root.join("app", "controllers", "application_controller.rb")
      if File.exist?(application) && includes_ruact_controller?(File.read(application))
        return [:pass, "whole-app mode: ApplicationController includes Ruact::Controller — " \
                       "#{pluralize_count(ruact_page_templates, 'template')} in app/views render through ruact"]
      end

      count = island_controllers.length
      return island_without_pages_result if count.zero?

      verb = count == 1 ? "renders" : "render"
      [:pass, "island mode: #{pluralize_count(count, 'controller')} #{verb} ruact pages (include Ruact::Controller)"]
    end

    # A real include line, not a mention in a comment.
    def includes_ruact_controller?(source)
      source.match?(/^[ \t]*include[ \t]+Ruact::Controller\b/)
    end

    def island_controllers
      Dir.glob(Rails.root.join("app", "controllers", "**", "*.rb").to_s).select do |file|
        !file.end_with?("/application_controller.rb") && includes_ruact_controller?(File.read(file))
      end
    end

    # Page templates: `.html.erb` under app/views, not layouts and not partials.
    def ruact_page_templates
      Dir.glob(Rails.root.join("app", "views", "**", "*.html.erb").to_s).count do |file|
        !file.include?("/app/views/layouts/") && !File.basename(file).start_with?("_")
      end
    end

    def pluralize_count(count, noun)
      "#{count} #{noun}#{'s' unless count == 1}"
    end

    def island_without_pages_result
      [:warn,
       "island mode: no controller renders ruact pages yet — add include Ruact::Controller to one, " \
       "or run rails generate ruact:scaffold",
       "The install changes no controller (island mode). A page renders through ruact when its " \
       "controller has `include Ruact::Controller`; narrow it with `ruact_pages only: %i[show]`. " \
       "`rails generate ruact:install --app` puts it on ApplicationController instead (every page)."]
    end

    # Which document a ruact page actually renders into, decided from
    # `Ruact.config.layout` and the files on disk — never by rendering.
    #
    # - `false`  → `[:shell, application.html.erb]`: ruact's built-in shell. The
    #   application layout is still read, to report a layout that is wired but
    #   switched off.
    # - a String → the app's `app/views/layouts/<name>.html.erb` when it exists
    #   (an ejected `ruact` layout included), otherwise the gem's own
    #   (`layouts/ruact`, Story 17.0b), otherwise `:missing`. The same order the
    #   view paths give Rails: the app's views first, the gem's appended last.
    #   The `layouts/` prefix Rails accepts is stripped rather than doubled.
    # - `true`   → `application.html.erb`. It cannot resolve a controller's own
    #   `layout "admin"`, and every message names the file it read so that
    #   limit stays visible.
    #
    # @return [Array(Symbol, Pathname)] `[:shell | :app | :gem | :missing, path]`
    def rendering_layout
      layout = Ruact.config.layout
      application = Rails.root.join("app", "views", "layouts", "application.html.erb")
      return [:shell, application] if layout == false
      return [File.exist?(application) ? :app : :missing, application] unless layout.is_a?(String)

      name = layout.delete_prefix("layouts/")
      app_file = Rails.root.join("app", "views", "layouts", "#{name}.html.erb")
      return [:app, app_file] if File.exist?(app_file)

      gem_file = Pathname(Ruact.views_path).join("layouts", "#{name}.html.erb")
      return [:gem, gem_file] if gem_file.exist?

      [:missing, app_file]
    end

    # Two independent halves have to line up, and BOTH are silent when wrong:
    # the layout has to call `ruact_js_assets`, and `Ruact.config.layout` has to
    # be on. Miss either and ruact renders its built-in shell — which carries no
    # stylesheet, so the app's own CSS never reaches a ruact page and nothing
    # errors. Reporting each half separately is the point: "add one line" and
    # "flip one setting" are different fixes.
    #
    # Story 17.0b — it reads the layout that RENDERS (see #rendering_layout). It
    # used to read application.html.erb always, which failed a correct fresh
    # install: that one renders through the gem's layout and leaves the app's
    # own untouched, with no React root in it.
    #
    # `Ruact::LayoutSource` is the SHARED definition of "calls the helper" —
    # the runtime and `ruact:install` read it too, so this check cannot drift
    # into disagreeing with what actually happens at render time (it did:
    # a `<%# TODO: add ruact_js_assets %>` comment used to pass here).
    def check_layout
      kind, path = rendering_layout
      return [:pass, "ruact pages render through ruact's layout (config.layout = \"#{Ruact::GEM_LAYOUT}\")"] if
        kind == :gem
      return layout_missing_result(path) unless File.exist?(path)

      missing = missing_layout_pieces(File.read(path))
      return layout_unwired_result(path, missing) unless missing.empty?
      return layout_not_opted_in_result if kind == :shell

      [:pass, "#{path.basename} owns the document (React root + ruact_js_assets, config.layout on)"]
    end

    def layout_missing_result(path)
      if Ruact.config.layout.is_a?(String)
        [:fail, "config.layout names #{path.basename}, which exists neither in your app nor in ruact",
         "Create #{path} (with <div id=\"root\"></div>, <%= ruact_js_assets %> and <%= ruact_head_assets %>), " \
         "or set config.layout = \"#{Ruact::GEM_LAYOUT}\" to use the layout ruact ships."]
      else
        [:fail, "React shell missing from #{path.basename}",
         "Create #{path}, or set config.layout = \"#{Ruact::GEM_LAYOUT}\" in config/initializers/ruact.rb " \
         "to render ruact pages through the layout ruact ships."]
      end
    end

    # Story 17.0b — the CSS half of the asset contract.
    #
    # Vite records client-component stylesheets on the bootstrap manifest entry.
    # If the build produced CSS and the layout never calls `ruact_head_assets`,
    # that CSS is served and never referenced: styling that works in development
    # and silently disappears in production.
    #
    # The decision is MECHANICAL — read the config, the manifest and the layout
    # that renders — and never an inference at render time. Layout auto-detection
    # was removed deliberately (see Ruact::Configuration#layout) and this must not
    # reintroduce it: `LayoutSource.head_wired?` runs through `without_comments`,
    # so a mention inside a comment does not read as wired.
    def check_head_assets
      entry = doctor_manifest_entry
      return head_assets_unreadable_result if entry == :unreadable

      kind, path = rendering_layout
      return head_assets_unbuilt_result(path) if entry.nil? && kind == :app && !head_wired_file?(path)

      css = Array(entry && entry["css"])
      return [:pass, "no client-component CSS in the build (nothing to link)"] if css.empty?

      return [:pass, "client-component CSS present; the built-in shell links it"] if kind == :shell
      return [:pass, "client-component CSS is linked by ruact's layout"] if kind == :gem
      return head_assets_no_layout_result(path) if kind == :missing
      return head_assets_missing_result(css.length, path) unless head_wired_file?(path)

      [:pass, "client-component CSS is linked (ruact_head_assets in #{path.basename})"]
    end

    def head_wired_file?(path)
      Ruact::LayoutSource.head_wired?(File.read(path))
    end

    # No build yet — the normal state in development with the Vite dev server,
    # which injects component CSS itself. A layout of the app's own that never
    # calls the helper passes there and loses that CSS in production, which is
    # exactly what this check exists to catch: a warning, not a pass.
    def head_assets_unbuilt_result(path)
      [:warn,
       "#{path.basename} does not call ruact_head_assets — client-component CSS will not reach production",
       "Add <%= ruact_head_assets %> as the first thing inside <head> in #{path}, above your " \
       "stylesheet_link_tag. There is no production build to check yet, so this is a warning; with " \
       "a build that emits component CSS it is a failure."]
    end

    def head_assets_no_layout_result(path)
      [:fail,
       "the build emits client-component CSS but #{path.basename} does not exist " \
       "(Ruact.config.layout points at it)",
       "Ruact.config.layout points at #{path}, which is not there. Create it (or set " \
       "config.layout = \"#{Ruact::GEM_LAYOUT}\") and add <%= ruact_head_assets %> inside its <head> — " \
       "otherwise the stylesheets Vite built for your client components are served and never referenced."]
    end

    # An unreadable manifest is NOT "nothing to link": the same file is parsed at
    # render time, where a parse error raises. Reporting :pass here would mean the
    # doctor is green on an app that 500s.
    def head_assets_unreadable_result
      [:fail,
       "public/assets/.vite/manifest.json exists but is not valid JSON — rebuild your assets",
       "Rebuild your assets (npm run build). ruact reads this file at render time, so a " \
       "truncated or corrupt manifest raises there rather than degrading."]
    end

    # The file goes in the MESSAGE, not only in the remediation: `Doctor#run`
    # prints `message` alone, so anything a reader needs in the terminal has to
    # be there. (Story 5.4 found the same asymmetry; the remediation reaches
    # `-- --json` only.)
    def head_assets_missing_result(count, path)
      [:fail,
       "the build emits #{count} client-component stylesheet(s) that nothing links " \
       "— add <%= ruact_head_assets %> to #{path.basename}",
       "Add <%= ruact_head_assets %> as the first thing inside <head> in #{path}, " \
       "ABOVE your stylesheet_link_tag so your own CSS is loaded last and wins ties " \
       "(ruact never edits your layout). " \
       "Without it that CSS is built and served but never referenced - styling that works in " \
       "development and vanishes in production."]
    end

    # The bootstrap manifest entry, or nil when there is no build to read. Kept
    # here rather than reaching into the view helper's private lookup.
    def doctor_manifest_entry
      manifest_path = Rails.root.join("public", "assets", ".vite", "manifest.json")
      return nil unless File.exist?(manifest_path)

      JSON.parse(File.read(manifest_path))[Ruact.bootstrap_virtual_id]
    rescue JSON::ParserError
      :unreadable
    end

    # The exact lines the layout lacks, named in the MESSAGE (`Doctor#run` prints
    # only the message; the remediation reaches `-- --json` alone).
    def missing_layout_pieces(content)
      missing = []
      missing << %(<div id="root"></div>) unless Ruact::LayoutSource.root?(content)
      missing << "<%= ruact_js_assets %>" unless Ruact::LayoutSource.wired?(content)
      missing
    end

    def layout_unwired_result(path, missing)
      [:fail, "#{path.basename} is missing #{missing.join(' and ')}",
       "Add #{missing.join(' and ')} to #{path} (the root div in <body>, the helper right after it). " \
       "#{layout_alternative(path)}Without both, ruact renders its built-in shell and your app's CSS never " \
       "reaches the page."]
    end

    # Suggesting `config.layout = "ruact"` to an app whose file IS the ejected
    # `ruact` layout would be advice to change nothing.
    def layout_alternative(path)
      return "" if path.basename.to_s == "#{Ruact::GEM_LAYOUT}.html.erb"

      "Or set config.layout = \"#{Ruact::GEM_LAYOUT}\" to use the layout ruact ships. "
    end

    def layout_not_opted_in_result
      [:warn, "layout is ready but Ruact.config.layout is false",
       "Your layout calls ruact_js_assets, but ruact is still rendering its built-in shell " \
       "(which has none of your stylesheets). Set `config.layout = true` in config/initializers/ruact.rb " \
       "to render through it, or `config.layout = \"#{Ruact::GEM_LAYOUT}\"` for the layout ruact ships."]
    end

    def check_streaming
      mode  = Ruact.streaming_mode || :buffered
      label = mode == :enabled ? "enabled" : "buffered"
      [:pass, "streaming: #{label} (#{streaming_server_hint})"]
    end

    # Detects host-app references to the legacy gem constant or require path
    # left over from the rename to `ruact`. Literal names are interpolated
    # from LEGACY_CONST / LEGACY_GEM so this file passes the gem-CI
    # `name-propagation` guard without an exclusion (Story 5.1 review F4).
    def check_legacy_constant
      offenses = LEGACY_SCAN_GLOBS.flat_map do |glob|
        Dir[Rails.root.join(glob)].flat_map do |file|
          File.foreach(file).with_index(1).filter_map do |line, lineno|
            next unless LEGACY_CONSTANT_RE.match?(line)

            "#{file}:#{lineno}"
          end
        end
      end
      return [:pass, "No legacy `#{LEGACY_CONST}` / `#{LEGACY_GEM}` references found"] if offenses.empty?

      [:fail,
       "Legacy `#{LEGACY_CONST}` / `#{LEGACY_GEM}` references found in #{offenses.length} location(s) " \
       "(first: #{offenses.first}). Replace `#{LEGACY_CONST}` with `Ruact` and " \
       "`require \"#{LEGACY_GEM}\"` with `require \"ruact\"` (gem renamed in v0.0.x). " \
       "See #{RENAME_DOC_URL}."]
    end

    # Story 13.1 (AC2) — fails when ruact's OWN Ruby source introduces an
    # inbound Flight-deserialization entry point that is not explicitly
    # annotated `# ruact:allow-flight-deserialization <reason>`. Passes silently
    # when none exists (the current tree). Scans `@serialize_only_root/**/*.rb`,
    # excluding this file and the generators' client-side templates.
    def check_serialize_only
      offenses = Dir[File.join(@serialize_only_root, "**", "*.rb")].flat_map do |file|
        next [] if File.expand_path(file) == DOCTOR_FILE
        next [] if file.match?(%r{/generators/.+/templates/})

        File.foreach(file).with_index(1).filter_map do |line, lineno|
          next unless DESERIALIZE_SIGNAL_RE.match?(line)
          next if line.include?(ALLOW_FLIGHT_DESERIALIZATION)

          "#{file}:#{lineno}"
        end
      end

      if offenses.empty?
        return [:pass, "Serialize-only invariant holds — no inbound Flight deserializer in ruact's Ruby source"]
      end

      [:fail,
       "Inbound Flight deserializer entry point found in #{offenses.length} location(s) " \
       "(first: #{offenses.first}). ruact is serialize-only: it may emit `text/x-component` " \
       "but must never deserialize externally-supplied Flight into live Ruby objects " \
       "(React2Shell / CVE-2025-55182 class). Remove it, or — if deliberate and reviewed — " \
       "annotate the line with `#{ALLOW_FLIGHT_DESERIALIZATION} <reason>`. See #{SERIALIZE_ONLY_DOC}."]
    end

    # Story 13.1 (AC3) — WARNS (never fails) when a response-transforming
    # middleware is mounted in the app's stack, since it may recompress/mutate a
    # streamed `text/x-component` Flight body and break the wire contract.
    def check_flight_middleware
      stack = flight_middleware_stack
      return [:pass, "No response-transforming middleware on the Flight wire path"] if stack.nil?

      present = stack.filter_map { |mw| middleware_name(mw) }
                     .select { |name| RESPONSE_TRANSFORMING_MIDDLEWARE.include?(name) }
                     .uniq
      return [:pass, "No response-transforming middleware on the Flight wire path"] if present.empty?

      [:warn,
       "#{present.join(', ')} is mounted and may transform `text/x-component` (Flight) responses, " \
       "breaking the wire contract / streaming. Exclude Flight responses from compression " \
       "(don't compress `text/x-component`) or mount it so it does not wrap the Flight routes.",
       "Exclude text/x-component from compression, or mount the middleware so it does not wrap Flight routes."]
    end

    # Returns the app middleware stack to scan, or nil when unavailable (no
    # Rails application present — e.g. the non-Rails / full-stub edge context).
    # At real `rails ruact:doctor` time the `:environment` task has booted the
    # app, so `app.middleware` is the enumerable `ActionDispatch::MiddlewareStack`.
    # Before `initialize!` it is a `Rails::Configuration::MiddlewareStackProxy`
    # (not enumerable) — skip it rather than crash on `filter_map`.
    def flight_middleware_stack
      return nil unless defined?(Rails) && Rails.respond_to?(:application)

      app = Rails.application
      return nil unless app.respond_to?(:middleware)

      stack = app.middleware
      stack.respond_to?(:each) ? stack : nil
    end

    def middleware_name(middleware)
      middleware.respond_to?(:name) ? middleware.name : middleware.to_s
    end

    def streaming_server_hint
      return "Puma"      if defined?(::Puma)
      return "Unicorn"   if defined?(::Unicorn)
      return "Passenger" if defined?(::PhusionPassenger)

      "unknown"
    end

    def manifest_path
      Ruact.config.manifest_path ||
        Rails.root.join("public", "react-client-manifest.json")
    end

    def format_result(status, message)
      case status
      when :pass then "✓ #{message}"
      when :warn then "⚠ #{message}"
      else            "✗ #{message}"
      end
    end
  end
end
