# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"
require "socket"

# The Rails stub (including Rails.root) is provided by spec/support/rails_stub.rb.
require "ruact/doctor"

RSpec.describe Ruact::Doctor do
  let(:tmpdir) { Pathname.new(Dir.mktmpdir) }

  before { Rails.root = tmpdir }
  after  { FileUtils.rm_rf(tmpdir) }

  # --- helpers ---

  def make_controller(with_include: true)
    dir = tmpdir.join("app", "controllers")
    FileUtils.mkdir_p(dir)
    content = with_include ? "include Ruact::Controller\n" : "class ApplicationController\nend\n"
    File.write(dir.join("application_controller.rb"), content)
  end

  def make_layout(with_sentinel: true)
    dir = tmpdir.join("app", "views", "layouts")
    FileUtils.mkdir_p(dir)
    content = with_sentinel ? "<%# ruact: root %>\n<div id=\"root\"></div>\n" : "<body></body>\n"
    File.write(dir.join("application.html.erb"), content)
  end

  def make_manifest
    dir = tmpdir.join("public")
    FileUtils.mkdir_p(dir)
    File.write(dir.join("react-client-manifest.json"), "{}")
  end

  # --- check_manifest ---

  describe "#check_manifest (AC#1, #2)" do
    subject(:doctor) { described_class.new }

    context "when manifest file exists" do
      before { make_manifest }

      it "returns :pass" do
        status, = doctor.send(:check_manifest)
        expect(status).to eq(:pass)
      end

      it "message includes 'Manifest found at'" do
        _, msg = doctor.send(:check_manifest)
        expect(msg).to include("Manifest found at")
      end
    end

    context "when manifest file is missing" do
      it "returns :fail" do
        status, = doctor.send(:check_manifest)
        expect(status).to eq(:fail)
      end

      it "message is 'Manifest not found — run vite build'" do
        _, msg = doctor.send(:check_manifest)
        expect(msg).to eq("Manifest not found — run vite build")
      end
    end
  end

  # --- check_vite ---

  describe "#check_vite (AC#1, #3)" do
    subject(:doctor) { described_class.new }

    context "when Vite is accessible" do
      before { allow(TCPSocket).to receive(:new).and_return(instance_double(TCPSocket, close: nil)) }

      it "returns :pass" do
        status, = doctor.send(:check_vite)
        expect(status).to eq(:pass)
      end
    end

    context "when Vite is not accessible" do
      before { allow(TCPSocket).to receive(:new).and_raise(Errno::ECONNREFUSED) }

      it "returns :fail" do
        status, = doctor.send(:check_vite)
        expect(status).to eq(:fail)
      end

      it "message is 'Vite not accessible at localhost:5173 — run npm run dev'" do
        _, msg = doctor.send(:check_vite)
        expect(msg).to eq("Vite not accessible at localhost:5173 — run npm run dev")
      end
    end
  end

  # --- check_controller ---

  describe "#check_controller (AC#1, #4)" do
    subject(:doctor) { described_class.new }

    context "when ApplicationController includes Ruact::Controller" do
      before { make_controller(with_include: true) }

      it "returns :pass" do
        status, = doctor.send(:check_controller)
        expect(status).to eq(:pass)
      end
    end

    context "when Ruact::Controller is not included" do
      before { make_controller(with_include: false) }

      it "returns :fail" do
        status, = doctor.send(:check_controller)
        expect(status).to eq(:fail)
      end

      it "message is 'Ruact::Controller not included in ApplicationController'" do
        _, msg = doctor.send(:check_controller)
        expect(msg).to eq("Ruact::Controller not included in ApplicationController")
      end
    end
  end

  # --- check_layout ---

  describe "#check_layout (AC#1, #5)" do
    subject(:doctor) { described_class.new }

    context "when layout contains the React shell sentinel" do
      before { make_layout(with_sentinel: true) }

      it "returns :pass" do
        status, = doctor.send(:check_layout)
        expect(status).to eq(:pass)
      end
    end

    context "when React shell sentinel is absent" do
      before { make_layout(with_sentinel: false) }

      it "returns :fail" do
        status, = doctor.send(:check_layout)
        expect(status).to eq(:fail)
      end

      it "message is 'React shell missing from application.html.erb'" do
        _, msg = doctor.send(:check_layout)
        expect(msg).to eq("React shell missing from application.html.erb")
      end
    end
  end

  # --- check_streaming ---

  describe "#check_streaming (AC#5)" do
    subject(:doctor) { described_class.new }

    after { Ruact.streaming_mode = nil }

    it "always returns :pass" do
      status, = doctor.send(:check_streaming)
      expect(status).to eq(:pass)
    end

    context "when streaming_mode is :enabled (AC#1, #5)" do
      before do
        Ruact.streaming_mode = :enabled
        stub_const("Puma", Module.new)
      end

      it "message includes 'enabled' and 'Puma'" do
        _, msg = doctor.send(:check_streaming)
        expect(msg).to include("enabled").and include("Puma")
      end
    end

    context "when streaming_mode is :buffered with no known server (AC#3, #5)" do
      before { Ruact.streaming_mode = :buffered }

      it "message includes 'buffered'" do
        _, msg = doctor.send(:check_streaming)
        expect(msg).to include("buffered")
      end
    end

    context "when streaming_mode is nil (not yet detected)" do
      before { Ruact.streaming_mode = nil }

      it "defaults to buffered in the message" do
        _, msg = doctor.send(:check_streaming)
        expect(msg).to include("buffered")
      end
    end
  end

  # --- check_legacy_constant ---

  describe "#check_legacy_constant (Story 5.1)" do
    subject(:doctor) { described_class.new }

    # Built via Array#join so this spec file passes the gem-CI
    # `name-propagation` guard without an exclusion (Story 5.1 review F4).
    let(:legacy_const) { %w[Rails Rsc].join }
    let(:legacy_gem)   { %w[rails rsc].join("_") }

    def make_initializer(content, filename: "ruact.rb")
      dir = tmpdir.join("config", "initializers")
      FileUtils.mkdir_p(dir)
      File.write(dir.join(filename), content)
    end

    def make_app_file(content, path:)
      dir = tmpdir.join("app", File.dirname(path))
      FileUtils.mkdir_p(dir)
      File.write(tmpdir.join("app", path), content)
    end

    context "when no legacy references exist" do
      it "returns :pass" do
        status, = doctor.send(:check_legacy_constant)
        expect(status).to eq(:pass)
      end
    end

    context "when an initializer references the legacy constant" do
      before { make_initializer("#{legacy_const}.configure do |c|\n  c.foo = 1\nend\n") }

      it "returns :fail" do
        status, = doctor.send(:check_legacy_constant)
        expect(status).to eq(:fail)
      end

      it "message names the file:line and instructs the rename" do
        _, msg = doctor.send(:check_legacy_constant)
        expect(msg).to include("ruact.rb:1")
        expect(msg).to include("Replace `#{legacy_const}` with `Ruact`")
      end

      it "message includes the rename documentation link (AC5)" do
        _, msg = doctor.send(:check_legacy_constant)
        expect(msg).to include("https://github.com/luizcg/ruact/blob/main/CHANGELOG.md#renamed")
      end
    end

    context "when an app file requires the legacy gem name" do
      before { make_app_file("require \"#{legacy_gem}\"\n", path: "models/foo.rb") }

      it "returns :fail" do
        status, = doctor.send(:check_legacy_constant)
        expect(status).to eq(:fail)
      end
    end

    context "when only the modern Ruact constant is referenced" do
      before { make_initializer("Ruact.configure { |c| c.foo = 1 }\n") }

      it "returns :pass" do
        status, = doctor.send(:check_legacy_constant)
        expect(status).to eq(:pass)
      end
    end

    context "when a word coincidentally contains the legacy substring" do
      # e.g. "TrailsRsce" should not trigger the regex (boundary check).
      before { make_initializer("# documenting TrailsRsce_engine here\n") }

      it "returns :pass" do
        status, = doctor.send(:check_legacy_constant)
        expect(status).to eq(:pass)
      end
    end
  end

  # --- run / .run ---

  describe ".run / #run (AC#1, #7)" do
    before do
      make_manifest
      make_controller(with_include: true)
      make_layout(with_sentinel: true)
      allow(TCPSocket).to receive(:new).and_return(instance_double(TCPSocket, close: nil))
    end

    context "when all checks pass" do
      it "returns true" do
        expect(described_class.run).to be true
      end

      it "does not print the fix hint" do
        expect { described_class.run }.not_to output(/rails generate/).to_stdout
      end
    end

    context "when any check fails" do
      before { allow(TCPSocket).to receive(:new).and_raise(Errno::ECONNREFUSED) }

      it "returns false" do
        expect(described_class.run).to be false
      end

      it "prints the fix hint" do
        expect { described_class.run }
          .to output(/Run rails generate ruact:install to fix configuration issues/).to_stdout
      end
    end
  end
end
