# frozen_string_literal: true

require "erb"
require "pathname"
require "rails/generators"
require "ruact"

module Ruact
  module Generators
    # Installs ruact into the current Rails application.
    #
    # Performs the following actions:
    # 1. Creates config/initializers/ruact.rb
    # 2. Injects `include Ruact::Controller` into ApplicationController
    # 3. Injects the React root div AND `ruact_js_assets` into
    #    app/views/layouts/application.html.erb, so the app's own layout owns
    #    the document (and its `<head>` — stylesheets, fonts, meta — reaches a
    #    ruact page). See Ruact::Configuration#layout.
    # 4. Creates app/javascript/components/.keep
    # 5. Creates vite.config.js (or shows manual instructions if one exists)
    # 6. Creates package.json (react/react-dom/vite/@vitejs/plugin-react) so a
    #    fresh app has JS deps to install (Story 14.6, FR101).
    # 7. Creates Procfile.dev + bin/dev (foreman) so the single `bin/dev`
    #    command boots BOTH Rails and the Vite dev server (Story 14.6, Epic 14
    #    DoD — a ruact app needs both processes).
    # 8. Emits AGENTS.md (marker-delimited, append-aware, idempotent) so coding
    #    agents working in the app have ruact's conventions, traps, and
    #    verification commands in context by default (Story 15.1, FR105).
    # 9. Runs `npm install` so JavaScript dependencies are ready (FR101);
    #    skippable via --skip-npm.
    # 10. With `--shadcn`: also emits the prerequisites shadcn's own CLI refuses
    #    to initialize without (a Tailwind entry + a `tsconfig.json` import
    #    alias), wires the `css` build process, and prints the two `npx shadcn`
    #    commands it deliberately does not run.
    #
    # Story 14.2 (FR104) — the generator no longer writes a bootstrap entry into
    # the user's tree. ruact's React entry is served as the virtual module
    # `virtual:ruact/bootstrap` by the bundled Vite plugin (the generated
    # `vite.config` input points at it), so a fresh install leaves
    # `app/javascript/` with only the user's `components/` (plus the gitignored,
    # typed `.ruact/server-functions.ts`).
    #
    # Run: rails generate ruact:install
    class InstallGenerator < Rails::Generators::Base # rubocop:disable Metrics/ClassLength
      source_root File.expand_path("templates", __dir__)

      desc "Installs ruact into the current Rails application"

      # Story 14.1 (FR101) — one-command install. By default the generator
      # runs `npm install` after writing every file so a fresh app is runnable
      # straight away. `--skip-npm` opts out (CI, or a non-npm package manager —
      # run the manager's install manually, then `bin/dev`).
      class_option :skip_npm,
                   type: :boolean,
                   default: false,
                   desc: "Skip running npm install (for CI or non-npm package managers)"

      # Prepares the app for the `ruact:scaffold --shadcn` path. shadcn's own
      # CLI refuses to initialize without BOTH Tailwind and a TypeScript import
      # alias, and a ruact app has neither — it ships no Tailwind and no
      # `tsconfig.json` at all. That left `--shadcn` scaffolding into an app
      # where the generated components' classes resolved to nothing: markup with
      # no styling. This flag emits exactly the prerequisites (verified against
      # the real shadcn CLI) and then PRINTS the two `npx shadcn` commands
      # rather than running them — they hit the network and `shadcn init` is
      # interactive, so automating them is neither safe nor possible.
      class_option :shadcn,
                   type: :boolean,
                   default: false,
                   desc: "Also wire Tailwind + a TS import alias, the prerequisites for `ruact:scaffold --shadcn`"

      def create_initializer
        template "initializer.rb.tt", "config/initializers/ruact.rb"
      end

      def inject_controller_concern
        controller_file = "app/controllers/application_controller.rb"
        return unless File.exist?(Pathname(destination_root).join(controller_file))

        content = File.read(Pathname(destination_root).join(controller_file))
        if content.include?("Ruact::Controller")
          say_status "skip", "Ruact::Controller already included in ApplicationController", :yellow
          return
        end

        inject_into_file controller_file,
                         "\n  include Ruact::Controller\n",
                         after: /class ApplicationController.*\n/
      end

      # The layout owns the document: `stylesheet_link_tag`, favicons, fonts and
      # every `<head>`-writing gem only reach a ruact page because Rails' own
      # layout renders it (see `Ruact::Configuration#layout`). That requires TWO
      # things in the layout — the React root, and `ruact_js_assets` to emit the
      # bootstrap entry + this render's Flight payload. Under the `:auto`
      # default a layout carrying only the root is treated as not-yet-migrated
      # and ruact keeps using its built-in (CSS-less) shell, so the helper is
      # what actually flips an app onto the layout path.
      def inject_layout_shell
        layout_file = "app/views/layouts/application.html.erb"
        return unless File.exist?(Pathname(destination_root).join(layout_file))

        content = File.read(Pathname(destination_root).join(layout_file))

        # A CALL, not a mention: `<%# TODO: add ruact_js_assets %>` used to read
        # as "already present" here and skip the migration, leaving the app on
        # ruact's CSS-less shell with the generator reporting success. Shared
        # with the runtime so both agree on what "migrated" means.
        if Ruact::LayoutSource.wired?(content)
          say_status "skip", "ruact root + assets already present in layout", :yellow
          return
        end

        # Migration path for an app installed before the layout owned the
        # document: the root is already there, only the asset call is missing.
        #
        # The anchor matches the ROOT DIV itself rather than the marker-then-div
        # pair, and tolerates the ways a real layout is written — single or
        # double quotes, extra attributes, any attribute order, CRLF, and the
        # marker on the same line. The earlier anchor required the exact emitted
        # formatting, so a hand-edited layout silently matched nothing. The
        # attribute boundary in `ROOT_ELEMENT` is what keeps `data-id="root"`
        # from being mistaken for the mount point.
        if content.include?("ruact: root")
          before = File.read(Pathname(destination_root).join(layout_file))
          inject_into_file layout_file,
                           "\n    <%= ruact_js_assets %>",
                           after: Ruact::LayoutSource::ROOT_ELEMENT
          after = File.read(Pathname(destination_root).join(layout_file))

          # `inject_into_file` prints "File unchanged!" and carries on when the
          # anchor misses, so a success message here would be a lie — and the app
          # would keep rendering through ruact's CSS-less shell with no clue why.
          if after == before
            warn_layout_migration_failed
          else
            say_status "update", "added ruact_js_assets to the existing layout root", :green
          end
          return
        end

        inject_into_file layout_file,
                         "\n    <%# ruact: root %>\n    <div id=\"root\"></div>\n    <%= ruact_js_assets %>\n",
                         before: "  </body>"
      end

      # `--shadcn` only. Two files, both of them things shadcn's CLI checks for
      # and refuses to proceed without ("No Tailwind CSS configuration found" /
      # "Could not find valid path aliases"), verified against shadcn 4.x:
      #
      #   app/javascript/styles/globals.css — the Tailwind entry. shadcn appends
      #     its design tokens here, which is why components.json points at it.
      #   tsconfig.json — the `@/*` → `app/javascript/*` alias. The Vite plugin
      #     already registers the same alias for the BUNDLER, so components
      #     resolve at runtime today; this is what makes it resolve for
      #     TypeScript (and therefore for shadcn's alias probe and your editor).
      #
      # Both are guarded: an app that already has them keeps its own.
      def create_shadcn_prerequisites
        return unless shadcn?

        create_guarded_file "app/javascript/styles/globals.css", "globals.css.tt"
        create_guarded_file "tsconfig.json", "tsconfig.json.tt"
        # Propshaft only serves directories that exist; the built stylesheet is
        # generated, so the directory ships with a .keep and the artifact is
        # gitignored (see append_gitignore_entries).
        empty_directory "app/assets/builds"
        create_file "app/assets/builds/.keep" unless
          File.exist?(Pathname(destination_root).join("app/assets/builds/.keep"))

        warn_unless_layout_links_builds
      end

      # The compiled stylesheet still has to be REQUESTED. Rails 8's default
      # layout links `stylesheet_link_tag :app`, which Propshaft expands over
      # every stylesheet on the load path — so `app/assets/builds/tailwind.css`
      # is picked up with no further wiring (verified against a generated app:
      # the rendered `<head>` carries `/assets/tailwind-<digest>.css`).
      #
      # A layout that instead links stylesheets BY NAME never asks for it, and
      # the failure is silent: Tailwind builds fine, Propshaft serves it fine,
      # and the page is simply unstyled. Warn rather than edit — which
      # stylesheets a layout links is the app's business.
      def warn_unless_layout_links_builds
        layout_path = Pathname(destination_root).join("app/views/layouts/application.html.erb")
        return unless layout_path.exist?

        content = layout_path.read
        return unless content.include?("stylesheet_link_tag")
        return if content.match?(/stylesheet_link_tag\s+:app\b/) || content.include?("tailwind")

        say_status "notice", "your layout links stylesheets by name — add the built one:", :yellow
        say ""
        say "      <%= stylesheet_link_tag \"tailwind\" %>"
        say ""
        say "  `stylesheet_link_tag :app` (the Rails 8 default) would pick up"
        say "  app/assets/builds/tailwind.css on its own; a named link does not,"
        say "  and the page would render unstyled with no error."
        say ""
      end

      def create_components_directory
        empty_directory "app/javascript/components"
        create_file "app/javascript/components/.keep" unless
          File.exist?(Pathname(destination_root).join("app/javascript/components/.keep"))
      end

      # Story 8.0a — scaffold the directory the codegen writes into and add the
      # generated artifacts to .gitignore. The TS module is regenerated on every
      # boot from the action and query registries, so it should never be
      # version-controlled; same for the bridge JSON under tmp/cache/.
      def create_server_functions_directory
        empty_directory "app/javascript/.ruact"
        create_file "app/javascript/.ruact/.gitkeep" unless
          File.exist?(Pathname(destination_root).join("app/javascript/.ruact/.gitkeep"))
      end

      def append_gitignore_entries
        gitignore = Pathname(destination_root).join(".gitignore")
        return unless gitignore.exist?

        entries = [
          "app/javascript/.ruact/server-functions.ts",
          "tmp/cache/ruact/"
        ]
        # The compiled stylesheet is a build artifact of globals.css, rebuilt by
        # the Procfile's `css` process on every boot — same reasoning as the
        # generated server-functions module above.
        entries << "app/assets/builds/tailwind.css" if shadcn?
        # Substring matches (`existing.include?(entry)`) were unsafe — they
        # would skip "tmp/cache/ruact/" when the file already contained
        # "tmp/cache/ruact/some-cache.bin", leaving the directory itself
        # un-ignored. Match by exact normalized line instead.
        existing_lines = File.read(gitignore).each_line.to_set { |line| line.chomp.strip }
        new_entries = entries.reject { |e| existing_lines.include?(e) }
        return if new_entries.empty?

        append_to_file ".gitignore", "\n# ruact (Story 8.0a — auto-generated server-functions module)\n"
        new_entries.each { |entry| append_to_file ".gitignore", "#{entry}\n" }
      end

      # Invokes `ruact:server_functions:generate` so a fresh install completes
      # with the AC8-required empty-but-valid generated module on disk.
      # Failures (a NameBridge violation, a collision, an unwritable
      # `tmp/cache/ruact/` directory) propagate intentionally — silencing
      # them via a rescue would let an install finish in a broken state, which
      # is the bug the Re-run review caught.
      def prime_server_functions_codegen
        rake "ruact:server_functions:generate"
      end

      def create_vite_config
        vite_config_file = Pathname(destination_root).join("vite.config.js")

        # `--force` must actually regenerate (the message below promises it). The
        # guard skips the template ONLY when the file exists AND force was not
        # passed; with --force we fall through to `template`, which overwrites.
        if vite_config_file.exist? && !options[:force]
          say_status "notice", "vite.config.js already exists — add the plugin manually:", :yellow
          say "  1. At the top of vite.config.js, add:"
          say "       import ruact from '#{Ruact.vite_plugin_path}';"
          say "  2. In the plugins array, add: ruact()"
          say "  3. Set build.rollupOptions.input to '#{Ruact.bootstrap_virtual_id}'"
          say ""
          say "  Re-run `rails generate ruact:install --force` to overwrite vite.config.js."
        else
          template "vite.config.js.tt", "vite.config.js"
        end
      end

      # Story 14.6 (FR101, Epic 14 DoD) — a fresh ruact app needs a package.json
      # declaring its JavaScript dependencies (React + Vite + the React Vite
      # plugin) so the `npm install` that Story 14.1 runs has something to
      # resolve and `bin/dev`'s `npm run dev` (Vite) has a `dev` script. The
      # bundled ruact Vite plugin is NOT a package.json dependency — vite.config
      # imports it by the absolute `Ruact.vite_plugin_path` and it uses only
      # `node:` builtins. Guarded like vite.config.js: an existing package.json
      # is left untouched (the app may already have one) unless --force.
      def create_package_json
        package_json_file = Pathname(destination_root).join("package.json")

        if package_json_file.exist? && !options[:force]
          say_status "skip", "package.json already exists — ensure it has react, react-dom, " \
                             "vite and @vitejs/plugin-react (re-run with --force to overwrite)", :yellow
          return
        end

        template "package.json.tt", "package.json"
      end

      # Story 14.6 (Epic 14 DoD) — emit `Procfile.dev` + a foreman-based `bin/dev`
      # so the literal `bin/dev` boots BOTH processes a ruact app needs: Rails
      # (HTML shell + Flight + server functions) and the Vite dev server
      # (React/HMR + the bundled ruact plugin). Without these, `bin/dev` would
      # start only Rails and the React assets would never be served.
      #
      # `Procfile.dev` is guarded (skip if present unless --force) — the app may
      # already drive its own processes through one. `bin/dev`, however, is
      # OWNED by ruact: see `install_foreman_launcher`. `bin/dev` is made
      # executable.
      def create_launch_files
        create_guarded_file "Procfile.dev", "Procfile.dev.tt"
        install_foreman_launcher
        # Ensure bin/dev is executable whether we just wrote it or it pre-existed
        # (a skipped, already-foreman launcher should still be runnable).
        chmod "bin/dev", 0o755, verbose: false if Pathname(destination_root).join("bin/dev").exist?
      end

      # Story 14.2 (FR104, AC7) — an app upgrading from the earlier layout still
      # has app/javascript/{application.jsx,flight-client.js,ruact-router.js} on
      # disk. The generator never deletes user files, so it prints the exact
      # manual steps to reach the hidden-plumbing layout — otherwise the app is
      # left half-wired, with the stale entry shadowing the virtual bootstrap.
      # No-op on a fresh install (none of those files exist).
      def advise_plumbing_migration
        stale = legacy_plumbing_files
        return if stale.empty?

        say_status "notice", "earlier ruact layout detected — finish the Story 14.2 migration:", :yellow
        say ""
        say "  ruact's bootstrap entry + Flight runtime are now hidden behind the"
        say "  virtual module '#{Ruact.bootstrap_virtual_id}' (served from the gem)."
        say "  Remove these now-obsolete files so they don't shadow the virtual entry:"
        stale.each { |f| say "    - delete #{f}" }
        say ""
        say "  Then set your vite.config build input to '#{Ruact.bootstrap_virtual_id}'"
        say "  (or re-run with --force to regenerate vite.config.js), and let the"
        say "  controller's HTML shell — or the `ruact_js_assets` view helper in your"
        say "  layout — emit the entry <script> tags."
        say ""
      end

      # Story 15.1 (FR105) — emit AGENTS.md so coding agents working in the app
      # have ruact's conventions, traps, and verification commands in context
      # by default. The ruact content is delimited by explicit markers
      # (`<!-- ruact:begin -->` / `<!-- ruact:end -->`) so the action can be
      # append-aware and idempotent:
      #
      #   no file                  → create it (the template IS the section)
      #   file without markers     → APPEND the marked section, every
      #                              pre-existing user byte preserved
      #   markers present          → skip (re-running install is zero-diff)
      #   markers present + --force → refresh ONLY the between-marker content —
      #                              deliberately narrower than the vite.config
      #                              full-overwrite posture, because a user's
      #                              AGENTS.md may carry their own project
      #                              instructions above/below ruact's section.
      #
      # Later stories (15.2 loud children error, 15.3 --json introspection,
      # 15.4 test helpers) evolve the template; `--force` after a gem upgrade
      # is the designed refresh path.
      def create_agents_md
        destination = Pathname(destination_root).join("AGENTS.md")

        return template("AGENTS.md.tt", "AGENTS.md") unless destination.exist?

        content = destination.read
        if agents_md_markers_well_formed?(content)
          refresh_or_skip_agents_md_section
        elsif agents_md_markers_broken?(content)
          warn_agents_md_broken_markers
        else
          append_agents_md_section(content)
        end
      end

      # Story 14.1 (FR101) — install JavaScript dependencies so a fresh app is
      # runnable in one command. Runs LAST among the file-producing actions
      # (after every file is written) so a failure here leaves the generated
      # files in place and reported. Records the outcome in @npm_outcome so
      # show_post_install_message can tell the truth about what happened.
      def install_javascript_dependencies
        if options[:skip_npm]
          @npm_outcome = :skipped
          say_status "skip", "npm install (--skip-npm) — install JS deps manually before bin/dev", :yellow
          return
        end

        unless npm_on_path?
          @npm_outcome = :unavailable
          warn_npm_unavailable
          return
        end

        # Thor's `run` returns false on a non-zero exit (Rails generators set
        # exit_on_failure? = false, so a failed `npm install` does NOT raise),
        # and nil under `--pretend` (the command is previewed, not executed).
        # Branch so the post-install message never claims deps are installed
        # when npm failed (AC#3) — and a `--pretend` dry run is NOT misreported
        # as a failure (run_npm_install still prints the previewed command).
        if run_npm_install || options[:pretend]
          @npm_outcome = options[:pretend] ? :pretend : :installed
        else
          @npm_outcome = :failed
          warn_npm_install_failed
        end
      end

      def show_post_install_message
        say "\n#{'=' * 60}\n  ruact installed successfully!\n#{'=' * 60}\n"

        if @npm_outcome == :installed
          say "JavaScript dependencies are installed."
          say ""
          say "Next step:"
          say "  Start your app:  bin/dev"
        else
          say "JavaScript dependencies are not yet installed."
          say ""
          say "Next steps:"
          say "  1. Install JS dependencies:  npm install"
          say "  2. Start your app:           bin/dev"
        end

        show_shadcn_next_steps if shadcn?

        say "\nThen add <MyComponent /> to any ERB view.\n"
        say "Note: re-run this generator after updating the ruact gem to refresh"
        say "the bundled Vite plugin path in vite.config.js."
        say ""
      end

      private

      # The generator does NOT run these: `shadcn init` is interactive (it
      # prompts for a component library and a preset) and both commands hit the
      # network. What it CAN do is spell them exactly, which is the part nobody
      # guesses: current shadcn defaults to **Base UI**, while ruact's generated
      # components import **Radix** primitives — accepting the default gives you
      # a component library the scaffold cannot use. Hence the explicit
      # `--base radix`.
      #
      # The component list is ruact's own authoritative set
      # (ScaffoldGenerator#required_shadcn_components), derived from the
      # templates' imports, so the two generators cannot drift.
      def show_shadcn_next_steps
        say ""
        say "shadcn prerequisites are in place (Tailwind entry, tsconfig alias, css process)."
        say "Two commands remain — they are interactive and hit the network, so run them yourself:"
        say ""
        say "  npx shadcn@latest init --base radix"
        say "  npx shadcn@latest add #{shadcn_add_list}"
        say ""
        say "  (--base radix matters: shadcn now defaults to Base UI, but the components"
        say "   `ruact:scaffold --shadcn` generates import Radix primitives.)"
        say "  (init also asks you to pick a style preset — any of them works.)"
        say ""
        say "Then scaffold a resource:"
        say "  bin/rails generate ruact:scaffold Post title:string body:text --shadcn"
      end

      # Story 15.1 — the exact marker tokens delimiting the ruact-managed
      # section of AGENTS.md. For a prose file the only safe idempotency key is
      # an explicit marker pair (`append_gitignore_entries`-style exact-line
      # dedup would misfire on edited prose).
      AGENTS_MD_BEGIN_MARKER = "<!-- ruact:begin -->"
      AGENTS_MD_END_MARKER   = "<!-- ruact:end -->"

      # The full marked section, non-greedy so nothing outside the marker pair
      # is ever captured (--force replaces exactly this range).
      AGENTS_MD_SECTION_RE = /#{Regexp.escape(AGENTS_MD_BEGIN_MARKER)}.*?#{Regexp.escape(AGENTS_MD_END_MARKER)}/m
      private_constant :AGENTS_MD_BEGIN_MARKER, :AGENTS_MD_END_MARKER, :AGENTS_MD_SECTION_RE

      # The rendered ruact section — the full AGENTS.md.tt body, begin marker
      # first line through end marker last line (the template IS the section).
      # Rendered through ERB in the generator's context so the template may
      # interpolate like any other Thor template (today it is fully static).
      def agents_md_section
        @agents_md_section ||= ERB.new(
          File.read(File.expand_path("templates/AGENTS.md.tt", __dir__)),
          trim_mode: "-"
        ).result(binding)
      end

      # Story 15.1 — append the marked ruact section to a user-authored
      # AGENTS.md, separated by exactly one blank line, preserving every
      # pre-existing byte.
      def append_agents_md_section(existing_content)
        separator = existing_content.end_with?("\n") ? "\n" : "\n\n"
        append_to_file "AGENTS.md", "#{separator}#{agents_md_section}"
      end

      # Story 15.1 — a WELL-FORMED marker pair is present (the caller matched
      # {AGENTS_MD_SECTION_RE}): skip (idempotent re-run) unless --force, which
      # replaces ONLY the content between (and including) the marker pair.
      # Bytes outside the markers are never touched.
      def refresh_or_skip_agents_md_section
        unless options[:force]
          say_status "skip", "AGENTS.md already carries the ruact section " \
                             "(re-run with --force to refresh it)", :yellow
          return
        end

        # Block form so `\`/`\1` sequences in the section are never treated as
        # backreferences by String#gsub.
        gsub_file("AGENTS.md", AGENTS_MD_SECTION_RE) { agents_md_section.chomp }
      end

      # Story 15.1 (Codex R1/R2) — the ONLY marker state the action manages:
      # exactly one begin marker, exactly one end marker, begin before end.
      # Anything else — a lone marker, end-before-begin, a stray extra marker
      # alongside a valid pair, multiple pairs — makes the section boundary
      # ambiguous, so it is handled as broken (warn + no-op) rather than
      # guessed at.
      def agents_md_markers_well_formed?(content)
        content.scan(AGENTS_MD_BEGIN_MARKER).length == 1 &&
          content.scan(AGENTS_MD_END_MARKER).length == 1 &&
          AGENTS_MD_SECTION_RE.match?(content)
      end

      # Story 15.1 (Codex R1) — SOME marker text is present but not in the one
      # well-formed shape above. The boundary is ambiguous in BOTH directions —
      # appending would duplicate content next to stray markers, and replacing
      # would have to guess the range — so the only byte-safe move is to warn
      # and leave every byte alone.
      def agents_md_markers_broken?(content)
        content.include?(AGENTS_MD_BEGIN_MARKER) || content.include?(AGENTS_MD_END_MARKER)
      end

      def warn_agents_md_broken_markers
        say_status "warn", "AGENTS.md has an incomplete ruact marker pair " \
                           "(#{AGENTS_MD_BEGIN_MARKER} … #{AGENTS_MD_END_MARKER}) — " \
                           "leaving the file untouched; restore both markers (or delete " \
                           "the partial ruact section) and re-run", :yellow
      end

      # Story 14.6 (live clean-room fix) — ruact OWNS `bin/dev`. The foreman
      # launcher is load-bearing: it boots BOTH Rails AND the Vite dev server,
      # and Vite is what writes `public/react-client-manifest.json`. Rails'
      # own `rails new` writes a `bin/dev` that starts ONLY `rails server` (no
      # Vite) — leaving that default in place makes a freshly-installed ruact
      # app 500 on its first render: Vite never runs, the manifest is never
      # written, and the boot-time manifest load leaves `Ruact.manifest` nil.
      # So unlike `Procfile.dev` (guarded), `bin/dev` is OVERWRITTEN to take
      # ownership — the same posture Story 14.3's scaffold takes over the
      # controller.
      #
      # The overwrite is skipped only when the existing `bin/dev` already drives
      # `Procfile.dev` through a process manager (our foreman launcher from a
      # prior install, or the developer's own foreman/overmind/hivemind setup).
      # That keeps re-running the generator idempotent (invariant 14.1 — no
      # churn on the second run) and never clobbers a deliberate launcher, while
      # still replacing the inert Rails default. Detection is content-based but
      # deliberately STRICTER than a bare `include?("Procfile.dev")` (Codex R1/R2):
      # neither a comment nor an `echo`/`printf` that merely names a foreman
      # command may suppress the overwrite, or the Rails-default-only-
      # `rails server` failure mode could survive. See {#foreman_launcher?}.
      def install_foreman_launcher
        bin_dev = Pathname(destination_root).join("bin/dev")

        if bin_dev.exist? && foreman_launcher?(bin_dev.read) && !options[:force]
          say_status "skip", "bin/dev already drives Procfile.dev (foreman launcher present)", :yellow
          return
        end

        template "dev.tt", "bin/dev", force: true
      end

      # Procfile process managers a foreman-style `bin/dev` may exec. A launcher
      # that INVOKES one of these against `Procfile.dev` already boots Vite (via
      # the same Procfile.dev ruact writes), so it is ruact-compatible.
      PROCFILE_RUNNERS = %w[foreman overmind hivemind node-foreman invoker].freeze
      private_constant :PROCFILE_RUNNERS

      # A line that INVOKES a known runner as its COMMAND — the runner is the
      # command word, after an optional leading `exec` / `bundle exec`. Anchoring
      # to command position (Codex R3) is what distinguishes a real launcher from
      # a mere mention: an `echo`/`printf`, an assignment like
      # `MSG="… foreman …"`, or a `command -v foreman` test never has the runner
      # in command position, and the trailing shell-token boundary `(?=\s|$)`
      # requires the runner to be a COMPLETE command word — so neither
      # `beforeman` nor `foreman-old`/`foreman.bak` is mistaken for the real
      # `foreman` (Codex R5). (A launcher prefixed with bare env assignments —
      # e.g. `PORT=3000 foreman …` — does NOT match and is simply re-owned by
      # ruact's equivalent foreman launcher; harmless, and far safer than the
      # inverse false-positive that would let the Rails-only `bin/dev` survive.)
      RUNNER_INVOCATION = Regexp.new(
        '\A\s*(?:exec\s+|bundle\s+exec\s+)*' \
        "(?:#{Regexp.union(PROCFILE_RUNNERS).source})" \
        '(?=\s|$)'
      )
      private_constant :RUNNER_INVOCATION

      # True when `content` actually invokes a Procfile runner against
      # `Procfile.dev` — some non-comment line both invokes a known runner
      # ({RUNNER_INVOCATION}) AND references `Procfile.dev`. The Rails-default
      # `bin/dev` runs only `rails server`, invokes no runner, and is correctly
      # taken over.
      def foreman_launcher?(content)
        content.each_line.any? do |line|
          # Drop any inline shell comment (` #…`) before inspecting the line, so
          # `Procfile.dev` named only in a trailing comment is not mistaken for a
          # real argument (Codex R4) — e.g. `foreman --version # …Procfile.dev`.
          code = line.strip.split(/\s+#/, 2).first.to_s
          next false if code.empty? || code.start_with?("#")

          code.match?(RUNNER_INVOCATION) && code.include?("Procfile.dev")
        end
      end

      # Story 14.6 — write a template only when the destination does not already
      # exist (unless --force), printing a skip notice otherwise. Keeps
      # create_launch_files idempotent and non-clobbering.
      def create_guarded_file(destination, template_name)
        if Pathname(destination_root).join(destination).exist? && !options[:force]
          say_status "skip", "#{destination} already exists (re-run with --force to overwrite)", :yellow
          return
        end

        template template_name, destination
      end

      # Story 14.6 — a valid, lowercase npm "name" for the generated package.json,
      # derived from the app directory. npm names must be lowercase and contain
      # only URL-safe characters; anything else collapses to a hyphen.
      def shadcn?
        options[:shadcn]
      end

      # Printed when the layout carries the ruact marker but the anchor found no
      # root div to inject after. Silence would be the dangerous outcome: the app
      # keeps rendering through ruact's CSS-less built-in shell, and nothing ever
      # says why.
      def warn_layout_migration_failed
        say_status "skip", "could not locate the React root div in the layout", :red
        say ""
        say "  ruact could not add `ruact_js_assets` automatically. Add it by hand,"
        say "  just after the root div in app/views/layouts/application.html.erb:"
        say ""
        say "      <div id=\"root\"></div>"
        say "      <%= ruact_js_assets %>"
        say ""
        say "  Without it your app's CSS cannot reach a ruact-rendered page."
        say ""
      end

      # The superset the scaffold generator narrows per resource. Loaded lazily
      # (and only under `--shadcn`) so a plain install never pays for the
      # scaffold generator's load, and so a failure to reach it degrades to the
      # literal list rather than aborting an otherwise-successful install.
      def shadcn_add_list
        require_relative "../scaffold/scaffold_shadcn_preflight"
        ScaffoldGenerator::ShadcnPreflight::ALL_SHADCN_COMPONENTS.join(" ")
      rescue StandardError
        "button input textarea switch select label badge table alert-dialog dropdown-menu"
      end

      def app_package_name
        base = File.basename(File.expand_path(destination_root))
        sanitized = base.downcase.gsub(/[^a-z0-9._-]/, "-").squeeze("-").gsub(/\A-+|-+\z/, "")
        sanitized.empty? ? "ruact-app" : sanitized
      end

      # Story 14.2 (AC7) — the earlier-layout plumbing files that must be removed
      # from the user's tree (the bootstrap entry + the per-app runtime copies).
      # Returns the relative paths that currently exist under destination_root.
      def legacy_plumbing_files
        %w[
          app/javascript/application.jsx
          app/javascript/flight-client.js
          app/javascript/ruact-router.js
        ].select { |rel| File.exist?(Pathname(destination_root).join(rel)) }
      end

      # The stubbable seam (AC#6): the literal shell-out lives here, isolated
      # so the generator spec can assert/stub it without invoking real npm or
      # hitting the network. Runs in the app root (destination_root) so it
      # picks up the app's package.json. Returns Thor's `run` result (truthy on
      # success, false on a non-zero exit) — captured inside the block so the
      # value is propagated regardless of `inside`'s return semantics.
      def run_npm_install
        result = nil
        inside(destination_root) { result = run "npm install" }
        result
      end

      # Cross-platform `npm`-on-PATH detection (AC#5). Honors PATHEXT on
      # Windows (npm ships as npm.cmd there); on POSIX the bare `npm` is
      # checked. Stubbed in specs to exercise both branches deterministically
      # without depending on the CI host having Node installed.
      def npm_on_path?
        exts = ENV.fetch("PATHEXT", "").split(File::PATH_SEPARATOR)
        exts = [""] if exts.empty?

        ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).any? do |dir|
          next false if dir.empty?

          exts.any? do |ext|
            candidate = File.join(dir, "npm#{ext}")
            File.file?(candidate) && File.executable?(candidate)
          end
        end
      end

      # Clear, actionable message (AC#5) when npm is unavailable — the written
      # files are NOT rolled back; the developer is pointed at Node or the
      # --skip-npm escape hatch. No raw Errno/NoMethodError stack trace leaks.
      def warn_npm_unavailable
        say_status "warn", "npm not found on PATH — skipping JavaScript dependency install", :yellow
        say ""
        say "  ruact wrote all of its files, but could NOT install JavaScript"
        say "  dependencies: `npm` is not available on your PATH."
        say ""
        say "  Install Node >= 20 (https://nodejs.org), then run `npm install`,"
        say "  or re-run with `--skip-npm` and install JS deps with your own"
        say "  package manager. Then start your app with `bin/dev`."
        say ""
      end

      # Reported when `npm install` ran but exited non-zero (AC#1/#3) — the
      # written files are kept; the developer is told to resolve the npm error
      # and re-run, and the post-install summary will NOT claim deps installed.
      def warn_npm_install_failed
        say_status "warn", "npm install did not complete successfully", :yellow
        say ""
        say "  ruact wrote all of its files, but `npm install` reported a failure."
        say "  Re-run `npm install` in the app root and resolve the npm error,"
        say "  then start your app with `bin/dev`."
        say ""
      end
    end
  end
end
