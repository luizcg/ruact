# frozen_string_literal: true

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
    # 3. Injects the React root div into app/views/layouts/application.html.erb
    # 4. Creates app/javascript/components/.keep
    # 5. Creates vite.config.js (or shows manual instructions if one exists)
    # 6. Creates app/javascript/application.jsx (or skips if one exists)
    # 7. Runs `npm install` so JavaScript dependencies are ready (FR101);
    #    skippable via --skip-npm.
    #
    # Run: rails generate ruact:install
    class InstallGenerator < Rails::Generators::Base
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

      def inject_layout_shell
        layout_file = "app/views/layouts/application.html.erb"
        return unless File.exist?(Pathname(destination_root).join(layout_file))

        content = File.read(Pathname(destination_root).join(layout_file))
        if content.include?("ruact: root")
          say_status "skip", "Rails RSC root already present in layout", :yellow
          return
        end

        inject_into_file layout_file,
                         "\n    <%# ruact: root %>\n    <div id=\"root\"></div>\n",
                         before: "  </body>"
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

        if vite_config_file.exist?
          say_status "notice", "vite.config.js already exists — add the plugin manually:", :yellow
          say "  1. At the top of vite.config.js, add:"
          say "       import ruact from '#{Ruact.vite_plugin_path}';"
          say "  2. In the plugins array, add: ruact()"
          say ""
          say "  Re-run `rails generate ruact:install --force` to overwrite vite.config.js."
        else
          template "vite.config.js.tt", "vite.config.js"
        end
      end

      def create_javascript_entry
        template "application.jsx.tt", "app/javascript/application.jsx"
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
        # exit_on_failure? = false, so a failed `npm install` does NOT raise) —
        # branch on that so the post-install message never claims deps are
        # installed when npm actually failed (AC#3).
        if run_npm_install
          @npm_outcome = :installed
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

        say "\nThen add <MyComponent /> to any ERB view.\n"
        say "Note: re-run this generator after updating the ruact gem to refresh"
        say "the bundled Vite plugin path in vite.config.js."
        say ""
      end

      private

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
