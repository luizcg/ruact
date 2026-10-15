# frozen_string_literal: true

require "spec_helper"
require "logger"
require "tmpdir"
require "fileutils"

# Story 19-3 — the page's JavaScript built by another ruact than the server's.
RSpec.describe Ruact::BuildSkew, :story_19_3 do
  before { described_class.reset! }
  after { described_class.reset! }

  describe ".skewed?" do
    it "is false only for this gem's version" do
      expect(described_class.skewed?(Ruact::VERSION)).to be(false)
      expect(described_class.skewed?("0.0.19")).to be(true)
      expect(described_class.skewed?(nil)).to be(true)
    end
  end

  describe ".message" do
    it "names both versions and the rebuild" do
      text = described_class.message("0.0.19", root: nil)
      expect(text).to include("built by ruact 0.0.19", "this server is ruact #{Ruact::VERSION}", "<Suspense>")
      expect(text).to include("npm run build", "bin/dev", "deploy it together with the server")
    end

    it "says the build recorded no version" do
      expect(described_class.message(nil, root: nil)).to include("an older ruact, one that did not record its version")
    end

    context "with a vite.config" do
      let(:root) { Dir.mktmpdir }

      after { FileUtils.rm_rf(root) }

      def config(body, name = "vite.config.js")
        File.write(File.join(root, name), body)
      end

      it "names an import of another installation's plugin, and what to import instead" do
        old = "/gems/ruact-0.0.6/vendor/javascript/vite-plugin-ruact/index.js"
        config("import react from '@vitejs/plugin-react';\nimport ruact from '#{old}';\n")
        text = described_class.message("0.0.6", root: root)
        expect(text).to include("vite.config.js imports ruact's Vite plugin from #{old}")
        expect(text).to include("import it from '#{Ruact.vite_plugin_path}'")
        expect(text.index("import it from")).to be < text.index("Rebuild the JavaScript")
      end

      it "says nothing of the import when it is this gem's plugin, absolute or relative" do
        config("import ruact from '#{Ruact.vite_plugin_path}';\n")
        expect(described_class.message(nil, root: root)).not_to include("imports ruact's Vite plugin")

        relative = Pathname(Ruact.vite_plugin_path).relative_path_from(Pathname(File.realpath(root))).to_s
        config(%(import ruact from "./#{relative}";\n))
        expect(described_class.message(nil, root: root)).not_to include("imports ruact's Vite plugin")
      end

      it "reads the first vite.config Vite would, in .mjs and .ts too" do
        config("import ruact from '/old/vite-plugin-ruact/index.js';\n", "vite.config.ts")
        expect(described_class.message(nil, root: root)).to include("vite.config.ts imports")
      end

      it "says nothing of an import built in JavaScript" do
        config("import ruact from `${gem}/vendor/javascript/vite-plugin-ruact/index.js`;\n")
        expect(described_class.message(nil, root: root)).not_to include("imports ruact's Vite plugin")
      end

      it "reads a vite.config that is not UTF-8 without raising" do
        File.binwrite(File.join(root, "vite.config.js"),
                      "// caf\xE9\nimport ruact from '/old/vite-plugin-ruact/index.js';\n".b)
        expect(described_class.message(nil, root: root)).to include("vite.config.js imports")
      end

      it "keeps the message UTF-8 when the paths are not ASCII" do
        allow(Ruact).to receive(:vite_plugin_path)
          .and_return("/Users/José/gems/ruact/vendor/javascript/vite-plugin-ruact/index.js")
        config("import ruact from '/Users/José/gems/ruact-0.0.6/vendor/javascript/vite-plugin-ruact/index.js';\n")
        text = described_class.message(nil, root: root)
        expect(text.encoding).to eq(Encoding::UTF_8)
        expect(text).to include("from /Users/José/gems/ruact-0.0.6/", "import it from '/Users/José/gems/ruact/")
      end

      it "says nothing of the import when it cannot read one (fail open)" do
        config("const ruact = (await import(pluginPath)).default;\n")
        expect(described_class.message(nil, root: root)).not_to include("imports ruact's Vite plugin")
      end
    end

    it "says nothing of the import without a vite.config" do
      Dir.mktmpdir { |dir| expect(described_class.message(nil, root: dir)).not_to include("imports") }
    end
  end

  describe ".note" do
    let(:logger) { instance_double(Logger, warn: nil, error: nil) }

    it "logs once per version a build recorded, and returns the message every time" do
      3.times { expect(described_class.note("0.0.19", logger: logger)).to include("ruact 0.0.19") }
      described_class.note(nil, logger: logger)
      described_class.note(nil, logger: logger)
      expect(logger).to have_received(:warn).with(a_string_starting_with("[ruact] ")).twice
    end

    it "logs at the level asked" do
      described_class.note("0.0.19", logger: logger, level: :error)
      expect(logger).to have_received(:error).once
    end

    it "is silent and returns nil for this gem's build" do
      expect(described_class.note(Ruact::VERSION, logger: logger)).to be_nil
      expect(logger).not_to have_received(:warn)
    end

    it "logs once when threads race for the first note" do
      Array.new(8) { Thread.new { described_class.note("0.0.19", logger: logger) } }.each(&:join)
      expect(logger).to have_received(:warn).once
    end
  end
end
