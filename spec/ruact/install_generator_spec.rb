# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"
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
  end
end
