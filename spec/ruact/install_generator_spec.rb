# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"
require "json"
require "ruact"

RSpec.describe Ruact do # rubocop:disable RSpec/SpecFilePathFormat
  describe ".vite_plugin_path" do
    it "returns a string" do
      expect(described_class.vite_plugin_path).to be_a(String)
    end

    it "points to an existing file (NFR15 — bundled plugin present in gem)" do
      expect(File.exist?(described_class.vite_plugin_path)).to be true
    end

    it "points to the vite-plugin-ruact index.js" do
      expect(described_class.vite_plugin_path).to end_with("vite-plugin-ruact/index.js")
    end

    it "contains the plugin export function" do
      content = File.read(described_class.vite_plugin_path)
      expect(content).to include("export default function ruact")
    end
  end

  describe ".configure / .config" do
    after { described_class.instance_variable_set(:@config, nil) }

    it "returns a Configuration instance" do
      expect(described_class.config).to be_a(Ruact::Configuration)
    end

    it "yields config to configure block" do
      described_class.configure { |c| c.suspense_timeout = 10.0 }
      expect(described_class.config.suspense_timeout).to eq(10.0)
    end

    it "returns the same instance on repeated calls (singleton)" do
      first  = described_class.config
      second = described_class.config
      expect(first).to be(second)
    end

    it "has sensible defaults" do
      config = described_class.config
      expect(config.manifest_path).to be_nil
      expect(config.strict_serialization).to be false
      expect(config.suspense_timeout).to eq(5.0)
      expect(config.vite_dev_server).to eq("http://localhost:5173")
    end
  end

  describe "generator action helpers" do
    # These tests exercise the core file-manipulation logic extracted from the generator
    # using plain Ruby + tmpdir — no Rails::Generators infrastructure required.

    let(:tmpdir) { Dir.mktmpdir("ruact_generator_spec") }

    after { FileUtils.rm_rf(tmpdir) }

    def write_file(relative_path, content)
      full = File.join(tmpdir, relative_path)
      FileUtils.mkdir_p(File.dirname(full))
      File.write(full, content)
      full
    end

    def read_file(relative_path)
      File.read(File.join(tmpdir, relative_path))
    end

    # Reproduces inject_controller_concern logic from the generator
    def inject_controller_concern(dest_root)
      controller_file = File.join(dest_root, "app/controllers/application_controller.rb")
      return :missing unless File.exist?(controller_file)

      content = File.read(controller_file)
      return :already_present if content.include?("Ruact::Controller")

      modified = content.sub(
        /^(class ApplicationController.*)\n/,
        "\\1\n  include Ruact::Controller\n"
      )
      File.write(controller_file, modified)
      :injected
    end

    # Reproduces inject_layout_shell logic from the generator
    def inject_layout_shell(dest_root)
      layout_file = File.join(dest_root, "app/views/layouts/application.html.erb")
      return :missing unless File.exist?(layout_file)

      content = File.read(layout_file)
      return :already_present if content.include?("ruact: root")

      modified = content.sub(
        "  </body>",
        "    <%# ruact: root %>\n    <div id=\"root\"></div>\n  </body>"
      )
      File.write(layout_file, modified)
      :injected
    end

    describe "ApplicationController injection (AC#1, AC#3)" do
      let(:controller_content) do
        "class ApplicationController < ActionController::Base\nend\n"
      end

      it "injects include Ruact::Controller after the class declaration" do
        write_file("app/controllers/application_controller.rb", controller_content)
        result = inject_controller_concern(tmpdir)

        expect(result).to eq(:injected)
        content = read_file("app/controllers/application_controller.rb")
        expect(content).to include("include Ruact::Controller")
      end

      it "returns :already_present on second run (idempotent, AC#3)" do
        write_file("app/controllers/application_controller.rb",
                   "class ApplicationController < ActionController::Base\n  include Ruact::Controller\nend\n")

        result = inject_controller_concern(tmpdir)
        expect(result).to eq(:already_present)
      end

      it "does not duplicate the include when run twice (AC#3)" do
        write_file("app/controllers/application_controller.rb", controller_content)
        inject_controller_concern(tmpdir)
        inject_controller_concern(tmpdir)

        content = read_file("app/controllers/application_controller.rb")
        occurrences = content.scan("Ruact::Controller").size
        expect(occurrences).to eq(1)
      end
    end

    describe "Layout injection (AC#1, AC#3)" do
      let(:layout_content) do
        <<~HTML
          <!DOCTYPE html>
          <html>
            <body>
              <%= yield %>
            </body>
          </html>
        HTML
      end

      it "injects the RSC root div before </body>" do
        write_file("app/views/layouts/application.html.erb", layout_content)
        result = inject_layout_shell(tmpdir)

        expect(result).to eq(:injected)
        content = read_file("app/views/layouts/application.html.erb")
        expect(content).to include('<div id="root"></div>')
        expect(content).to include("ruact: root")
      end

      it "returns :already_present on second run (idempotent, AC#3)" do
        content_with_marker = layout_content.sub(
          "  </body>",
          "    <%# ruact: root %>\n    <div id=\"root\"></div>\n  </body>"
        )
        write_file("app/views/layouts/application.html.erb", content_with_marker)

        result = inject_layout_shell(tmpdir)
        expect(result).to eq(:already_present)
      end

      it "does not duplicate the root div when run twice (AC#3)" do
        write_file("app/views/layouts/application.html.erb", layout_content)
        inject_layout_shell(tmpdir)
        inject_layout_shell(tmpdir)

        content = read_file("app/views/layouts/application.html.erb")
        occurrences = content.scan('<div id="root">').size
        expect(occurrences).to eq(1)
      end

      it "places the root div before the closing </body> tag" do
        write_file("app/views/layouts/application.html.erb", layout_content)
        inject_layout_shell(tmpdir)

        content = read_file("app/views/layouts/application.html.erb")
        root_pos  = content.index('<div id="root">')
        body_pos  = content.index("</body>")
        expect(root_pos).to be < body_pos
      end
    end

    describe "vite.config.js template (AC#2)" do
      let(:template_path) do
        File.expand_path(
          "../../lib/generators/ruact/install/templates/vite.config.js.tt",
          __dir__
        )
      end

      it "references Ruact.vite_plugin_path in the generated content" do
        expect(File.read(template_path)).to include("Ruact.vite_plugin_path")
      end

      it "does not reference a hardcoded npm package name" do
        content = File.read(template_path)
        expect(content).not_to include("from 'vite-plugin-ruact'")
        expect(content).not_to include('from "vite-plugin-ruact"')
      end
    end

    describe "server-functions scaffold (Story 8.0a — AC8)", :story_8_0a do
      # Reproduces append_gitignore_entries logic from the install generator
      # so the spec can be expressed without a full Rails::Generators::TestCase.
      let(:gitignore_entries) do
        [
          "app/javascript/.ruact/server-functions.ts",
          "tmp/cache/ruact/"
        ]
      end

      # Mirror of the real generator's append_gitignore_entries logic
      # (gem/lib/generators/ruact/install/install_generator.rb). Kept in sync
      # at line-set membership granularity — the previous substring-based
      # version drifted from the real generator after the Chunk 1 review's
      # line-set fix and the Re-run 2026-05-14 patch brings this helper
      # back into parity.
      def append_gitignore_entries(dest_root)
        gitignore = File.join(dest_root, ".gitignore")
        return :no_gitignore unless File.exist?(gitignore)

        existing_lines = File.read(gitignore).each_line.to_set { |line| line.chomp.strip }
        new_entries = gitignore_entries.reject { |e| existing_lines.include?(e) }
        return :already_present if new_entries.empty?

        File.open(gitignore, "a") do |io|
          io.puts
          io.puts "# ruact (Story 8.0a — auto-generated server-functions module)"
          new_entries.each { |entry| io.puts entry }
        end
        :appended
      end

      def create_gitkeep(dest_root)
        keep = File.join(dest_root, "app/javascript/.ruact/.gitkeep")
        FileUtils.mkdir_p(File.dirname(keep))
        return :already_present if File.exist?(keep)

        File.write(keep, "")
        :created
      end

      it "creates .ruact/.gitkeep so the directory is checkable in (Story 8.0a)" do
        result = create_gitkeep(tmpdir)
        expect(result).to eq(:created)
        expect(File).to exist(File.join(tmpdir, "app/javascript/.ruact/.gitkeep"))
      end

      it "appends both .gitignore entries when missing (Story 8.0a)", :aggregate_failures do
        write_file(".gitignore", "/tmp\n")
        append_gitignore_entries(tmpdir)
        content = read_file(".gitignore")
        expect(content).to include("app/javascript/.ruact/server-functions.ts")
        expect(content).to include("tmp/cache/ruact/")
        # Story 9.9 — the v1 parallel `.next` target was demolished; the
        # generator must no longer scaffold its gitignore entry.
        expect(content).not_to include("server-functions.next.ts")
      end

      it "is idempotent — running twice does not duplicate entries (Story 8.0a — pitfall #5)" do
        write_file(".gitignore", "/tmp\n")
        append_gitignore_entries(tmpdir)
        append_gitignore_entries(tmpdir)

        content = read_file(".gitignore")
        expect(content.scan("app/javascript/.ruact/server-functions.ts").size).to eq(1)
        expect(content.scan("tmp/cache/ruact/").size).to eq(1)
      end

      it "does not write to .gitignore when both entries already exist" do
        write_file(".gitignore", "/tmp\napp/javascript/.ruact/server-functions.ts\n" \
                                 "tmp/cache/ruact/\n")
        result = append_gitignore_entries(tmpdir)
        expect(result).to eq(:already_present)
      end

      it "still appends 'tmp/cache/ruact/' when only a longer prefix-matching path is present " \
         "(Re-run 2026-05-14 — line-set semantics, not substring)", :aggregate_failures do
        # The Chunk 1 review's line-set fix makes the real generator append
        # `tmp/cache/ruact/` even when the file already contains a deeper
        # path like `tmp/cache/ruact/some-cache.bin`. The helper used to
        # use substring matching, which would skip the entry — a silent
        # drift between helper and generator. This test pins the helper
        # to the same semantics.
        write_file(".gitignore", "/tmp\ntmp/cache/ruact/some-cache.bin\n")
        append_gitignore_entries(tmpdir)
        content = read_file(".gitignore")
        # Exact-line match: a new "tmp/cache/ruact/" line is appended even
        # though the file already contains "tmp/cache/ruact/some-cache.bin"
        expect(content.each_line.to_a).to include("tmp/cache/ruact/\n")
        expect(content).to include("app/javascript/.ruact/server-functions.ts")
      end
    end

    # REGRESSION (Sprint Change Proposal 2026-06-16 §4.5): a fresh `rails new`
    # crashed `rails generate ruact:install` on Rails 8.1 / Thor because the
    # generator called `destination_root.join(...)` — Thor returns
    # `destination_root` as a String (`File.expand_path`), which has no
    # path-style `#join`, so the installer raised `NoMethodError` before writing
    # a single file. The fix wraps every site in `Pathname(destination_root)`.
    #
    # The "generator action helpers" tests above reimplement the file logic with
    # `File.join`, so they never run Thor's path handling and masked the bug.
    # These tests invoke the REAL generator against a String destination_root, so
    # a revert of the Pathname fix fails loudly here.
    describe "real generator invocation against a String destination_root" do
      require "stringio"
      require "generators/ruact/install/install_generator"

      let(:app_root) { Dir.mktmpdir("ruact_install_real") }

      after { FileUtils.rm_rf(app_root) }

      def build_generator(root)
        Ruact::Generators::InstallGenerator.new([], {}, destination_root: root)
      end

      def silently
        original = $stdout
        $stdout = StringIO.new
        yield
      ensure
        $stdout = original
      end

      before do
        FileUtils.mkdir_p(File.join(app_root, "app/controllers"))
        File.write(File.join(app_root, "app/controllers/application_controller.rb"),
                   "class ApplicationController < ActionController::Base\nend\n")
        FileUtils.mkdir_p(File.join(app_root, "app/views/layouts"))
        File.write(File.join(app_root, "app/views/layouts/application.html.erb"),
                   "<!DOCTYPE html>\n<html>\n  <body>\n    <%= yield %>\n  </body>\n</html>\n")
        File.write(File.join(app_root, ".gitignore"), "/log/*\n")
      end

      it "hands the generator a String destination_root (the exact crashing condition)" do
        expect(build_generator(app_root).destination_root).to be_a(String)
      end

      it "runs every path-touching action without raising and writes the files", :aggregate_failures do
        gen = build_generator(app_root)

        silently do
          expect do
            gen.inject_controller_concern
            gen.inject_layout_shell
            gen.create_components_directory
            gen.create_server_functions_directory
            gen.append_gitignore_entries
            gen.create_vite_config
            gen.create_agents_md
          end.not_to raise_error
        end

        expect(File.read(File.join(app_root, "app/controllers/application_controller.rb")))
          .to include("include Ruact::Controller")
        expect(File.read(File.join(app_root, "app/views/layouts/application.html.erb")))
          .to include('<div id="root"></div>')
        expect(File).to exist(File.join(app_root, "app/javascript/components/.keep"))
        expect(File).to exist(File.join(app_root, "app/javascript/.ruact/.gitkeep"))
        expect(File.read(File.join(app_root, ".gitignore")))
          .to include("app/javascript/.ruact/server-functions.ts")
        expect(File).to exist(File.join(app_root, "vite.config.js"))
        expect(File).to exist(File.join(app_root, "AGENTS.md"))
      end
    end
  end

  # Story 14.1 (FR101) — one-command install: `ruact:install` now runs
  # `npm install` by default (behind a stubbable `run_npm_install` seam),
  # skippable via `--skip-npm`, with an npm-on-PATH guard and outcome-aware
  # post-install messaging. The shell-out is ALWAYS stubbed here — no real
  # npm / network call is made in CI. Reuses the "real generator against a
  # String destination_root" pattern (instantiate + call action methods).
  describe "install generator — one-command npm install (Story 14.1 — FR101)", :story_14_1 do
    require "stringio"
    require "generators/ruact/install/install_generator"

    let(:app_root) { Dir.mktmpdir("ruact_install_npm") }

    after { FileUtils.rm_rf(app_root) }

    def build_generator(root, opts = {})
      Ruact::Generators::InstallGenerator.new([], opts, destination_root: root)
    end

    def silently
      original = $stdout
      $stdout = StringIO.new
      yield
    ensure
      $stdout = original
    end

    # Captures and returns the generator's say/say_status stdout for text asserts.
    def capture_stdout
      original = $stdout
      $stdout = StringIO.new
      yield
      $stdout.string
    ensure
      $stdout = original
    end

    describe "--skip-npm class option (AC#2)", :aggregate_failures do
      it "is registered as a boolean class_option defaulting to false" do
        option = Ruact::Generators::InstallGenerator.class_options[:skip_npm]
        expect(option).not_to be_nil
        expect(option.type).to eq(:boolean)
        expect(option.default).to be false
      end
    end

    describe "default run installs JS deps (AC#1, AC#6a)" do
      it "invokes the run_npm_install seam exactly once" do
        gen = build_generator(app_root)
        allow(gen).to receive_messages(npm_on_path?: true, run_npm_install: true)

        silently { gen.install_javascript_dependencies }

        expect(gen).to have_received(:run_npm_install).once
        expect(gen.instance_variable_get(:@npm_outcome)).to eq(:installed)
      end

      it "runs the npm step AFTER the file-producing actions and BEFORE show_post_install_message",
         :aggregate_failures do
        # Thor runs public action methods in SOURCE definition order, so assert
        # on source line numbers (public_instance_methods order is not
        # guaranteed to match definition order). Story 14.2 removed
        # create_javascript_entry; create_vite_config is the last file-writing
        # action before the npm step.
        klass = Ruact::Generators::InstallGenerator
        line = ->(name) { klass.instance_method(name).source_location.last }
        expect(line.call(:create_vite_config)).to be < line.call(:install_javascript_dependencies)
        expect(line.call(:install_javascript_dependencies)).to be < line.call(:show_post_install_message)
      end
    end

    describe "run_npm_install seam (AC#6a)", :aggregate_failures do
      it "shells out `npm install` inside the destination_root" do
        gen = build_generator(app_root)
        allow(gen).to receive(:inside).and_yield
        allow(gen).to receive(:run)

        silently { gen.send(:run_npm_install) }

        expect(gen).to have_received(:inside).with(gen.destination_root)
        expect(gen).to have_received(:run).with("npm install")
      end
    end

    describe "--skip-npm opts out (AC#2, AC#6b)" do
      it "does not invoke the run_npm_install seam and emits a skip notice" do
        gen = build_generator(app_root, { skip_npm: true })
        allow(gen).to receive(:run_npm_install)

        output = capture_stdout { gen.install_javascript_dependencies }

        expect(gen).not_to have_received(:run_npm_install)
        expect(output).to match(/skip/i)
      end
    end

    describe "--pretend dry run", :aggregate_failures do
      # Thor's `run` returns nil under --pretend (the command is previewed, not
      # executed) — that must NOT be misread as an npm failure.
      it "treats a pretend run as a no-op, not an npm failure" do
        gen = build_generator(app_root, { pretend: true })
        allow(gen).to receive_messages(npm_on_path?: true, run_npm_install: nil)

        run_output = capture_stdout { gen.install_javascript_dependencies }

        expect(gen.instance_variable_get(:@npm_outcome)).to eq(:pretend)
        expect(run_output).not_to match(/did not complete|reported a failure/i)
      end
    end

    describe "npm not on PATH (AC#5)", :aggregate_failures do
      it "does not raise, skips the seam, and prints an actionable message naming --skip-npm" do
        gen = build_generator(app_root)
        allow(gen).to receive(:npm_on_path?).and_return(false)
        allow(gen).to receive(:run_npm_install)

        output = nil
        expect { output = capture_stdout { gen.install_javascript_dependencies } }
          .not_to raise_error
        expect(gen).not_to have_received(:run_npm_install)
        expect(output).to include("--skip-npm")
        expect(output).to match(/npm/i)
        expect(output).to match(/node/i)
      end
    end

    describe "post-install message reflects the outcome (AC#3)", :aggregate_failures do
      it "states deps are installed and next step is bin/dev when npm ran" do
        gen = build_generator(app_root)
        allow(gen).to receive_messages(npm_on_path?: true, run_npm_install: true)
        silently { gen.install_javascript_dependencies }

        output = capture_stdout { gen.show_post_install_message }
        expect(output).to include("are installed")
        expect(output).not_to include("not yet installed")
        expect(output).to include("bin/dev")
      end

      # AC#3 — Thor's `run` returns false on a non-zero exit (generators do not
      # exit_on_failure?), so a FAILED `npm install` must NOT report success.
      it "does NOT claim deps are installed when npm install fails (AC#3)" do
        gen = build_generator(app_root)
        allow(gen).to receive_messages(npm_on_path?: true, run_npm_install: false)

        run_output = capture_stdout { gen.install_javascript_dependencies }
        message    = capture_stdout { gen.show_post_install_message }

        expect(gen.instance_variable_get(:@npm_outcome)).to eq(:failed)
        expect(run_output).to match(/did not complete|failure/i)
        expect(message).not_to include("are installed")
        expect(message).to include("not yet installed")
        expect(message).to include("bin/dev")
      end

      it "tells the developer to install manually then bin/dev when skipped" do
        gen = build_generator(app_root, { skip_npm: true })
        silently { gen.install_javascript_dependencies }

        output = capture_stdout { gen.show_post_install_message }
        expect(output).to include("not yet installed")
        expect(output).to include("npm install")
        expect(output).to include("bin/dev")
      end
    end
  end

  # Story 14.2 (FR104) — the generator no longer leaks ruact plumbing into the
  # user's tree. After a fresh install, `app/javascript/` holds only the user's
  # `components/` (+ the gitignored typed `.ruact/server-functions.ts`); the
  # bootstrap entry is the virtual module `virtual:ruact/bootstrap`, and
  # `flight-client.js` / `ruact-router.js` live inside the gem.
  describe "install generator — hidden plumbing, no app/javascript leak (Story 14.2 — FR104)", :story_14_2 do
    require "stringio"
    require "generators/ruact/install/install_generator"

    let(:app_root) { Dir.mktmpdir("ruact_install_1402") }

    after { FileUtils.rm_rf(app_root) }

    def build_generator(root, opts = {})
      Ruact::Generators::InstallGenerator.new([], opts, destination_root: root)
    end

    def silently
      original = $stdout
      $stdout = StringIO.new
      yield
    ensure
      $stdout = original
    end

    before do
      FileUtils.mkdir_p(File.join(app_root, "app/controllers"))
      File.write(File.join(app_root, "app/controllers/application_controller.rb"),
                 "class ApplicationController < ActionController::Base\nend\n")
      FileUtils.mkdir_p(File.join(app_root, "app/views/layouts"))
      File.write(File.join(app_root, "app/views/layouts/application.html.erb"),
                 "<!DOCTYPE html>\n<html>\n  <body>\n    <%= yield %>\n  </body>\n</html>\n")
      File.write(File.join(app_root, ".gitignore"), "/log/*\n")
    end

    it "does NOT define a create_javascript_entry action (no application.jsx writer)" do
      expect(Ruact::Generators::InstallGenerator.instance_methods).not_to include(:create_javascript_entry)
    end

    it "no longer ships the application.jsx template (its source moved into the gem runtime)" do
      template = File.expand_path(
        "../../lib/generators/ruact/install/templates/application.jsx.tt", __dir__
      )
      expect(File).not_to exist(template)
    end

    it "writes no application.jsx / flight-client.js / ruact-router.js into app/javascript", :aggregate_failures do
      gen = build_generator(app_root)
      silently do
        gen.create_components_directory
        gen.create_server_functions_directory
        gen.append_gitignore_entries
        gen.create_vite_config
      end

      expect(File).not_to exist(File.join(app_root, "app/javascript/application.jsx"))
      expect(File).not_to exist(File.join(app_root, "app/javascript/flight-client.js"))
      expect(File).not_to exist(File.join(app_root, "app/javascript/ruact-router.js"))
      # The user's components dir + the typed registry scaffold still exist.
      expect(File).to exist(File.join(app_root, "app/javascript/components/.keep"))
      expect(File).to exist(File.join(app_root, "app/javascript/.ruact/.gitkeep"))
    end

    it "keeps the .ruact/server-functions.ts gitignore entry unchanged (server-functions.ts stays)" do
      gen = build_generator(app_root)
      silently { gen.append_gitignore_entries }
      expect(File.read(File.join(app_root, ".gitignore")))
        .to include("app/javascript/.ruact/server-functions.ts")
    end

    describe "migration advisory for an earlier-layout app (AC7 — no half-wired state)" do
      def capture_stdout
        original = $stdout
        $stdout = StringIO.new
        yield
        $stdout.string
      ensure
        $stdout = original
      end

      it "prints the exact delete steps + virtual entry when stale plumbing files exist", :aggregate_failures do
        %w[application.jsx flight-client.js ruact-router.js].each do |f|
          FileUtils.mkdir_p(File.join(app_root, "app/javascript"))
          File.write(File.join(app_root, "app/javascript", f), "// stale\n")
        end
        gen = build_generator(app_root)
        output = capture_stdout { gen.advise_plumbing_migration }

        expect(output).to match(/earlier ruact layout detected/i)
        expect(output).to include("delete app/javascript/application.jsx")
        expect(output).to include("delete app/javascript/flight-client.js")
        expect(output).to include("delete app/javascript/ruact-router.js")
        expect(output).to include(described_class.bootstrap_virtual_id)
        expect(output).to include("ruact_js_assets")
      end

      it "is a no-op on a fresh install (no stale files → no notice)" do
        gen = build_generator(app_root)
        output = capture_stdout { gen.advise_plumbing_migration }
        expect(output).to be_empty
      end
    end

    describe "vite.config input targets the virtual bootstrap (AC3 — single source of truth)" do
      let(:template_path) do
        File.expand_path("../../lib/generators/ruact/install/templates/vite.config.js.tt", __dir__)
      end

      it "renders the input from Ruact.bootstrap_virtual_id, not a hardcoded application.jsx", :aggregate_failures do
        content = File.read(template_path)
        expect(content).to include("Ruact.bootstrap_virtual_id")
        # The `input:` line must NOT hardcode the old application.jsx entry
        # (a prose mention in a comment is fine — only the directive matters).
        expect(content).not_to match(%r{input:\s*['"]app/javascript/application\.jsx['"]})
      end

      it "the generated input equals the id the ViewHelper/prod manifest lookup uses (no drift)" do
        gen = build_generator(app_root)
        silently { gen.create_vite_config }
        generated = File.read(File.join(app_root, "vite.config.js"))
        expect(generated).to include("input: '#{described_class.bootstrap_virtual_id}'")
      end

      it "leaves an existing vite.config.js untouched when --force is not passed" do
        File.write(File.join(app_root, "vite.config.js"), "// hand-written\n")
        gen = build_generator(app_root)
        silently { gen.create_vite_config }
        expect(File.read(File.join(app_root, "vite.config.js"))).to eq("// hand-written\n")
      end

      it "actually regenerates an existing vite.config.js under --force (the message's promise)", :aggregate_failures do
        File.write(File.join(app_root, "vite.config.js"), "// hand-written\n")
        gen = build_generator(app_root, { force: true })
        silently { gen.create_vite_config }
        regenerated = File.read(File.join(app_root, "vite.config.js"))
        expect(regenerated).not_to include("hand-written")
        expect(regenerated).to include("input: '#{described_class.bootstrap_virtual_id}'")
      end
    end
  end

  # Story 14.6 (FR101, Epic 14 DoD) — `ruact:install` now emits the missing
  # launch pieces so the literal `bin/dev` produces a working app: a
  # `package.json` (so 14.1's `npm install` resolves React + Vite) and a
  # `Procfile.dev` + foreman `bin/dev` that boot BOTH Rails and the Vite dev
  # server. Each is guarded (non-clobbering, --force overwrites) and idempotent.
  describe "install generator — launch files: package.json + Procfile.dev + bin/dev (Story 14.6)",
           :story_14_6 do
    require "stringio"
    require "generators/ruact/install/install_generator"

    let(:app_root) { Dir.mktmpdir("ruact_install_1406") }

    after { FileUtils.rm_rf(app_root) }

    def build_generator(root, opts = {})
      Ruact::Generators::InstallGenerator.new([], opts, destination_root: root)
    end

    def silently
      original = $stdout
      $stdout = StringIO.new
      yield
    ensure
      $stdout = original
    end

    describe "create_package_json (AC#1 — JS deps to install)", :aggregate_failures do
      it "writes a package.json declaring React + Vite (and a `dev` script)" do
        gen = build_generator(app_root)
        silently { gen.create_package_json }

        path = File.join(app_root, "package.json")
        expect(File).to exist(path)
        pkg = JSON.parse(File.read(path))
        expect(pkg.dig("dependencies", "react")).to be_a(String)
        expect(pkg.dig("dependencies", "react-dom")).to be_a(String)
        expect(pkg.dig("devDependencies", "vite")).to be_a(String)
        expect(pkg.dig("devDependencies", "@vitejs/plugin-react")).to be_a(String)
        expect(pkg.dig("scripts", "dev")).to eq("vite")
        expect(pkg["type"]).to eq("module")
      end

      it "does NOT list the bundled ruact Vite plugin as an npm dependency " \
         "(vite.config imports it by absolute path)" do
        gen = build_generator(app_root)
        silently { gen.create_package_json }
        expect(File.read(File.join(app_root, "package.json"))).not_to include("vite-plugin-ruact")
      end

      it "derives a valid lowercase npm name from the app directory" do
        gen = build_generator(app_root)
        silently { gen.create_package_json }
        name = JSON.parse(File.read(File.join(app_root, "package.json")))["name"]
        expect(name).to match(/\A[a-z0-9._-]+\z/)
      end

      it "leaves an existing package.json untouched without --force (non-clobbering)" do
        File.write(File.join(app_root, "package.json"), %({ "name": "mine" }\n))
        gen = build_generator(app_root)
        silently { gen.create_package_json }
        expect(File.read(File.join(app_root, "package.json"))).to eq(%({ "name": "mine" }\n))
      end

      it "overwrites an existing package.json under --force" do
        File.write(File.join(app_root, "package.json"), %({ "name": "mine" }\n))
        gen = build_generator(app_root, { force: true })
        silently { gen.create_package_json }
        expect(File.read(File.join(app_root, "package.json"))).to include("\"vite\"")
      end
    end

    describe "create_launch_files (Epic DoD — bin/dev boots both processes)", :aggregate_failures do
      it "writes Procfile.dev with BOTH a Rails web process and a Vite process" do
        gen = build_generator(app_root)
        silently { gen.create_launch_files }

        procfile = File.read(File.join(app_root, "Procfile.dev"))
        expect(procfile).to match(/^web:.*rails server/)
        expect(procfile).to match(/^vite:.*npm run dev/)
      end

      it "writes an executable bin/dev that execs foreman against Procfile.dev" do
        gen = build_generator(app_root)
        silently { gen.create_launch_files }

        dev = File.join(app_root, "bin/dev")
        expect(File).to exist(dev)
        expect(File).to be_executable(dev)
        body = File.read(dev)
        expect(body).to include("foreman start -f Procfile.dev")
        expect(body).to include("gem install foreman")
      end

      # Live clean-room fix — ruact OWNS bin/dev. `rails new` (Rails 8.x) writes a
      # bin/dev that starts ONLY `rails server`; left in place, Vite never runs,
      # the client manifest is never written, and the first render 500s. So the
      # foreman launcher must TAKE OVER that default rather than skip it.
      it "takes ownership of the Rails-default bin/dev (one that only runs rails server)" do
        FileUtils.mkdir_p(File.join(app_root, "bin"))
        File.write(File.join(app_root, "bin/dev"),
                   %(#!/usr/bin/env ruby\nexec "./bin/rails", "server", *ARGV\n))

        gen = build_generator(app_root)
        silently { gen.create_launch_files }

        body = File.read(File.join(app_root, "bin/dev"))
        expect(body).to include("foreman start -f Procfile.dev")
        expect(body).not_to include('exec "./bin/rails", "server"')
        expect(File).to be_executable(File.join(app_root, "bin/dev"))
      end

      # Idempotency (invariant 14.1) — re-running the generator must not churn:
      # the bin/dev we wrote already drives Procfile.dev, so the second run skips
      # it. (Detection is content-based: our launcher execs foreman against
      # Procfile.dev, so a marker comment proves the file was NOT rewritten.)
      it "is idempotent — a second run does not rewrite the foreman bin/dev it already wrote" do
        gen = build_generator(app_root)
        silently { gen.create_launch_files }

        marked = "#{File.read(File.join(app_root, 'bin/dev'))}# ruact-idempotency-marker\n"
        File.write(File.join(app_root, "bin/dev"), marked)

        gen2 = build_generator(app_root)
        silently { gen2.create_launch_files }
        expect(File.read(File.join(app_root, "bin/dev"))).to include("# ruact-idempotency-marker")
      end

      # Codex R1 — detection must be stricter than a bare `include?("Procfile.dev")`:
      # a bin/dev that only NAMES Procfile.dev in a comment (but still runs only
      # `rails server`) must be taken over, not skipped — else the 500 survives.
      it "takes ownership when Procfile.dev appears only in a comment (runs only rails server)" do
        FileUtils.mkdir_p(File.join(app_root, "bin"))
        File.write(File.join(app_root, "bin/dev"),
                   %(#!/usr/bin/env ruby\n# TODO: switch to Procfile.dev + foreman one day\n) +
                   %(exec "./bin/rails", "server", *ARGV\n))

        gen = build_generator(app_root)
        silently { gen.create_launch_files }

        body = File.read(File.join(app_root, "bin/dev"))
        expect(body).to include("foreman start -f Procfile.dev")
        expect(body).not_to include('exec "./bin/rails", "server"')
      end

      # Codex R2/R3 — a runner name that is only MENTIONED (not invoked as the
      # command) must not count as a real launcher. Each of these bin/dev files
      # names "foreman"/"Procfile.dev" somewhere but actually runs `rails server`,
      # so each must be taken over (else the original 500 survives).
      [
        ["echoed in a string",
         %(echo "switch to: foreman start -f Procfile.dev"\nexec ./bin/rails server\n)],
        ["assigned to a variable",
         %(MSG="switch to: foreman start -f Procfile.dev"\nexec ./bin/rails server\n)],
        ["named inside a command -v test",
         %(if command -v foreman; then echo Procfile.dev; fi\nexec ./bin/rails server\n)],
        ["referenced only in an inline comment on a runner diagnostic line",
         %(foreman --version # TODO: switch to Procfile.dev\nexec ./bin/rails server\n)],
        ["a runner look-alike command (not the real runner)",
         %(foreman-old start -f Procfile.dev\nexec ./bin/rails server\n)]
      ].each do |(label, contents)|
        it "takes ownership when a foreman command is only #{label} (still runs rails server)" do
          FileUtils.mkdir_p(File.join(app_root, "bin"))
          File.write(File.join(app_root, "bin/dev"), "#!/usr/bin/env bash\n#{contents}")

          gen = build_generator(app_root)
          silently { gen.create_launch_files }

          body = File.read(File.join(app_root, "bin/dev"))
          expect(body).to include("gem install foreman")
          expect(body).not_to include("exec ./bin/rails server")
        end
      end

      # Non-clobbering of a DELIBERATE foreman launcher — a developer's own
      # bin/dev that already drives Procfile.dev is ruact-compatible and is left
      # untouched (it boots Vite via the same Procfile.dev ruact writes).
      it "leaves a developer's existing foreman launcher (driving Procfile.dev) untouched" do
        FileUtils.mkdir_p(File.join(app_root, "bin"))
        File.write(File.join(app_root, "bin/dev"),
                   "#!/usr/bin/env bash\n# my custom launcher\nexec foreman start -f Procfile.dev\n")

        gen = build_generator(app_root)
        silently { gen.create_launch_files }
        expect(File.read(File.join(app_root, "bin/dev"))).to include("# my custom launcher")
      end

      it "overwrites even a Procfile.dev-driving launcher under --force" do
        FileUtils.mkdir_p(File.join(app_root, "bin"))
        File.write(File.join(app_root, "bin/dev"),
                   "#!/usr/bin/env bash\n# my custom launcher\nexec foreman start -f Procfile.dev\n")

        gen = build_generator(app_root, { force: true })
        silently { gen.create_launch_files }
        body = File.read(File.join(app_root, "bin/dev"))
        expect(body).to include("gem install foreman")
        expect(body).not_to include("# my custom launcher")
      end
    end

    describe "action ordering (npm install needs package.json on disk first)" do
      it "defines create_package_json BEFORE install_javascript_dependencies", :aggregate_failures do
        klass = Ruact::Generators::InstallGenerator
        line = ->(name) { klass.instance_method(name).source_location.last }
        expect(line.call(:create_package_json)).to be < line.call(:install_javascript_dependencies)
        expect(line.call(:create_launch_files)).to be < line.call(:install_javascript_dependencies)
      end
    end
  end

  # Story 15.1 (FR105) — `ruact:install` emits an AGENTS.md teaching coding
  # agents the ruact conventions, traps, and verification commands. The ruact
  # content is delimited by explicit markers so re-runs are idempotent, a
  # user-authored AGENTS.md is appended to (never clobbered), and --force
  # refreshes ONLY the marked section. Content assertions grep stable tokens
  # (commands, file paths, API names) — never full-file snapshots, since later
  # stories (15.2/15.3/15.4) deliberately evolve the prose.
  describe "install generator — AGENTS.md emission (Story 15.1 — FR105)", :story_15_1 do
    require "stringio"
    require "generators/ruact/install/install_generator"

    let(:app_root) { Dir.mktmpdir("ruact_install_1501") }
    let(:agents_md_path) { File.join(app_root, "AGENTS.md") }
    let(:begin_marker) { "<!-- ruact:begin -->" }
    let(:end_marker) { "<!-- ruact:end -->" }
    let(:template_path) do
      File.expand_path("../../lib/generators/ruact/install/templates/AGENTS.md.tt", __dir__)
    end

    after { FileUtils.rm_rf(app_root) }

    def build_generator(root, opts = {})
      Ruact::Generators::InstallGenerator.new([], opts, destination_root: root)
    end

    def silently
      original = $stdout
      $stdout = StringIO.new
      yield
    ensure
      $stdout = original
    end

    # Captures and returns the generator's say/say_status stdout for text asserts.
    def capture_stdout
      original = $stdout
      $stdout = StringIO.new
      yield
      $stdout.string
    ensure
      $stdout = original
    end

    describe "fresh emission (AC#1)" do
      it "creates AGENTS.md delimited by the ruact markers", :aggregate_failures do
        silently { build_generator(app_root).create_agents_md }

        expect(File).to exist(agents_md_path)
        content = File.read(agents_md_path)
        expect(content).to start_with(begin_marker)
        expect(content.rstrip).to end_with(end_marker)
      end

      it "covers the model, codegen, queries and verification areas", :aggregate_failures do
        silently { build_generator(app_root).create_agents_md }
        content = File.read(agents_md_path)

        # The verb rule (mutations = non-GET routed actions on Ruact::Server)
        expect(content).to include("Ruact::Server")
        expect(content).to include("non-GET")
        # Route-driven codegen: ground-truth file + regenerate command
        expect(content).to include("app/javascript/.ruact/server-functions.ts")
        expect(content).to include("bin/rails ruact:server_functions:generate")
        # Queries (reads)
        expect(content).to include("Ruact::Query")
        expect(content).to include("app/queries/")
        expect(content).to include("ruact_queries")
        expect(content).to include("useQuery")
        # Verification commands (the only two that exist today)
        expect(content).to include("bin/rails ruact:doctor")
        # Docs pointers
        expect(content).to include("https://ruact.dev")
        expect(content).to include("llms.txt")
      end

      it "covers the five traps and the safety areas", :aggregate_failures do
        silently { build_generator(app_root).create_agents_md }
        content = File.read(agents_md_path)

        # Trap 1 — children unsupported / self-closing only
        expect(content).to include("self-closing")
        expect(content).to include("children")
        # Trap 2 — Ruby (not JS) inside {} props
        expect(content).to include("Ruby, not JavaScript")
        # Trap 3 — Accept-header dual shape (exact application/json)
        expect(content).to include("Accept")
        expect(content).to include("application/json")
        # Trap 4 — ruact_errors fall-through
        expect(content).to include("ruact_errors")
        expect(content).to include("fall-through")
        # Trap 5 — name derivation from routes
        expect(content).to include("createPost")
        expect(content).to include("ruact_function_name")
        # Serialization allowlist
        expect(content).to include("ruact_props")
        expect(content).to include("strict_serialization")
        # SGID helpers (purpose + expiry required grain)
        expect(content).to include("Ruact.signed_global_id")
        expect(content).to include("Ruact.locate_signed")
      end

      it "makes no claim before its artifact (AC#4 — content honesty)", :aggregate_failures do
        silently { build_generator(app_root).create_agents_md }
        content = File.read(agents_md_path)

        # (The loud children `PreprocessorError` is Story 15.2's shipped
        # artifact, and the `--json` introspection commands are Story 15.3's —
        # both may now be claimed; see the `:story_15_2` / `:story_15_3` guards
        # below that PIN each claim's presence. Story 15.4's test helpers are not
        # yet shipped, so nothing may reference them as existing.)
        #
        # tsc does not run in a fresh install (no typescript devDep / tsconfig) —
        # it may only appear conditionally phrased (D1).
        expect(content).to match(/if your app has typescript tooling/i) if content.include?("tsc")
        # Volatile strings must not be quoted: no gem version pins.
        expect(content).not_to match(/\b0\.0\.\d+\b/)
      end

      # Story 15.2 (D2) — now that the loud children error is a shipped artifact,
      # trap #1 truthfully claims it fails LOUDLY (was "fails silently" in 15.1).
      it "trap #1 claims the loud PreprocessorError (Story 15.2 D2)", :aggregate_failures, :story_15_2 do
        silently { build_generator(app_root).create_agents_md }
        content = File.read(agents_md_path)

        expect(content).to include("PreprocessorError")
        expect(content).to match(/fail LOUDLY/i)
        expect(content).not_to match(/fail silently/i)
      end

      # Story 15.3 (D2) — now that the `--json` introspection surface is a shipped
      # artifact, the "Verify your work" section references it (relaxes the 15.1
      # honesty guard above). This PINS the claim AND its EXPERIMENTAL framing so
      # the template never presents the JSON shape as a stable contract.
      it "references --json introspection as EXPERIMENTAL (15.3 D2)", :aggregate_failures, :story_15_3 do
        silently { build_generator(app_root).create_agents_md }
        content = File.read(agents_md_path)

        expect(content).to include("ruact:routes -- --json")
        expect(content).to include("ruact:doctor")
        expect(content).to include("Append `-- --json`")
        expect(content).to match(/EXPERIMENTAL/)
        expect(content).to include("schema_version")
      end
    end

    describe "idempotency (AC#2 — double-run zero diff)" do
      it "leaves the file byte-identical on a second run and reports a skip", :aggregate_failures do
        silently { build_generator(app_root).create_agents_md }
        first = File.read(agents_md_path)

        output = capture_stdout { build_generator(app_root).create_agents_md }

        expect(File.read(agents_md_path)).to eq(first)
        expect(output).to include("skip")
      end
    end

    describe "append mode (AC#2 — user-authored AGENTS.md)" do
      let(:user_content) { "# My app\n\nUse pnpm here. Never touch config/secrets.yml.\n" }

      it "appends the marked section preserving every pre-existing user byte", :aggregate_failures do
        File.write(agents_md_path, user_content)

        silently { build_generator(app_root).create_agents_md }
        content = File.read(agents_md_path)

        expect(content).to start_with(user_content)
        expect(content.scan(begin_marker).count).to eq(1)
        expect(content.scan(end_marker).count).to eq(1)
        expect(content).to include("\n\n#{begin_marker}")
      end

      it "blank-line separates the section when the user file lacks a trailing newline" do
        File.write(agents_md_path, "# My app — no trailing newline")

        silently { build_generator(app_root).create_agents_md }

        expect(File.read(agents_md_path))
          .to include("# My app — no trailing newline\n\n#{begin_marker}")
      end

      it "appending then re-running is idempotent (skip, zero diff)" do
        File.write(agents_md_path, user_content)
        silently { build_generator(app_root).create_agents_md }
        appended = File.read(agents_md_path)

        silently { build_generator(app_root).create_agents_md }

        expect(File.read(agents_md_path)).to eq(appended)
      end
    end

    describe "--force refresh (AC#2 — marked-block-only)" do
      it "replaces ONLY the between-marker content, never user bytes outside", :aggregate_failures do
        silently { build_generator(app_root).create_agents_md }
        section = File.read(agents_md_path)
        stale = section.sub("## Five traps", "## STALE CONTENT FROM AN OLDER GEM")
        File.write(agents_md_path, "# mine, above\n\n#{stale}\n# mine, below\n")

        silently { build_generator(app_root, { force: true }).create_agents_md }
        content = File.read(agents_md_path)

        expect(content).to start_with("# mine, above\n")
        expect(content).to end_with("# mine, below\n")
        expect(content).to include("## Five traps")
        expect(content).not_to include("STALE CONTENT FROM AN OLDER GEM")
        expect(content.scan(begin_marker).count).to eq(1)
      end

      it "creates the file under --force when none exists" do
        silently { build_generator(app_root, { force: true }).create_agents_md }
        expect(File.read(agents_md_path)).to include(begin_marker)
      end
    end

    # Codex R1 — an incomplete marker state is ambiguous in BOTH directions
    # (appending would duplicate content next to a stray marker; replacing
    # would guess the range), so the only byte-safe move is warn + no-op.
    describe "broken marker pair (byte-safety)" do
      [
        ["a begin marker without its end marker",
         "# mine\n\n<!-- ruact:begin -->\ntruncated ruact section, no end marker\n"],
        ["an end marker without its begin marker",
         "# mine\n\nstray tail of a ruact section\n<!-- ruact:end -->\n"],
        ["an end marker preceding the begin marker",
         "# mine\n\n<!-- ruact:end -->\nreversed\n<!-- ruact:begin -->\n"],
        # Codex R2 — a VALID pair plus stray extra markers is still ambiguous:
        # skip/refresh would leave (or eat past) the unmatched marker.
        ["a stray end marker before a valid pair",
         "<!-- ruact:end -->\nstray\n\n<!-- ruact:begin -->\nsection\n<!-- ruact:end -->\n"],
        ["a stray begin marker after a valid pair",
         "<!-- ruact:begin -->\nsection\n<!-- ruact:end -->\n\nstray\n<!-- ruact:begin -->\n"],
        ["two complete marker pairs",
         "<!-- ruact:begin -->\none\n<!-- ruact:end -->\n\n<!-- ruact:begin -->\ntwo\n<!-- ruact:end -->\n"]
      ].each do |(label, broken)|
        it "warns and leaves the file untouched with #{label} (no --force)", :aggregate_failures do
          File.write(agents_md_path, broken)

          output = capture_stdout { build_generator(app_root).create_agents_md }

          expect(File.read(agents_md_path)).to eq(broken)
          expect(output).to include("warn")
        end

        it "warns and leaves the file untouched with #{label} (--force)", :aggregate_failures do
          File.write(agents_md_path, broken)

          output = capture_stdout { build_generator(app_root, { force: true }).create_agents_md }

          expect(File.read(agents_md_path)).to eq(broken)
          expect(output).to include("warn")
        end
      end
    end

    describe "action ordering + template budget" do
      it "defines create_agents_md BEFORE install_javascript_dependencies" do
        klass = Ruact::Generators::InstallGenerator
        line = ->(name) { klass.instance_method(name).source_location.last }
        expect(line.call(:create_agents_md)).to be < line.call(:install_javascript_dependencies)
      end

      # AC#3 tripwire — the ~150-line budget is the epic's scope probe; the
      # tripwire's tolerance is 160 (the tripwire's, not the product contract's).
      it "keeps the template body at or under 160 lines" do
        expect(File.read(template_path).lines.count).to be <= 160
      end
    end
  end
end
