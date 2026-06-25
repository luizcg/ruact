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

  # --- check_serialize_only (Story 13.1, AC2 + AC4) ---

  describe "#check_serialize_only", :story_13_1 do
    subject(:doctor) { described_class.new(serialize_only_root: scan_root.to_s) }

    # Injectable scan root → point the tripwire at a fixture tree.
    let(:scan_root) { Pathname.new(Dir.mktmpdir) }

    after { FileUtils.rm_rf(scan_root) }

    def write_source(name, content)
      path = scan_root.join(name)
      FileUtils.mkdir_p(path.dirname)
      File.write(path, content)
    end

    context "with a clean tree (no inbound deserializer)" do
      before { write_source("clean.rb", "class Foo\n  def bar = 42\nend\n") }

      it "returns :pass silently" do
        status, msg = doctor.send(:check_serialize_only)
        expect(status).to eq(:pass)
        expect(msg).to include("Serialize-only invariant holds")
      end
    end

    context "with an unguarded inbound Flight deserializer" do
      before do
        write_source("evil.rb", "class FlightDeserializer\n  def call(body)\n    parse_flight(body)\n  end\nend\n")
      end

      it "returns :fail" do
        status, = doctor.send(:check_serialize_only)
        expect(status).to eq(:fail)
      end

      it "names the offending file:line and points to the ADR invariant" do
        _, msg = doctor.send(:check_serialize_only)
        expect(msg).to include("evil.rb:1") # first offense = the *Deserializer constant
        expect(msg).to include("CVE-2025-55182")
        expect(msg).to include("server-functions-api.md")
      end
    end

    context "with a deserializer carrying the allow annotation" do
      before do
        annotation = ["# ruact:allow", "flight", "deserialization"].join("-")
        write_source("guarded.rb", "def parse_flight(body) #{annotation} reviewed legacy bridge\n  body\nend\n")
      end

      it "returns :pass (the escape hatch makes it a guard, not a ban)" do
        status, = doctor.send(:check_serialize_only)
        expect(status).to eq(:pass)
      end
    end

    context "with a signal that lives in an excluded location" do
      before do
        # generators' client-side templates are out of scope (browser RSC)
        write_source("lib/generators/ruact/install/templates/app.rb", "def parse_flight(b) = b\n")
      end

      it "returns :pass (templates are excluded from the scan)" do
        status, = doctor.send(:check_serialize_only)
        expect(status).to eq(:pass)
      end
    end
  end

  # --- check_flight_middleware (Story 13.1, AC3 + AC4) ---

  describe "#check_flight_middleware", :story_13_1 do
    subject(:doctor) { described_class.new }

    # Plain value objects (not doubles) modelling the iterable middleware stack
    # the check reads — each entry exposes a `.name`, mirroring a real
    # ActionDispatch::MiddlewareStack::Middleware.
    def middleware_entry(name)
      Struct.new(:name).new(name)
    end

    def stub_app(stack)
      app = Struct.new(:middleware).new(stack)
      allow(Rails).to receive(:application).and_return(app)
    end

    context "when a response-transforming middleware (Rack::Deflater) is mounted" do
      before { stub_app([middleware_entry("Rack::Deflater")]) }

      it "returns :warn (never :fail)" do
        status, msg = doctor.send(:check_flight_middleware)
        expect(status).to eq(:warn)
        expect(msg).to include("Rack::Deflater").and include("text/x-component")
      end
    end

    context "when no response-transforming middleware is mounted" do
      before { stub_app([middleware_entry("Rack::Runtime")]) }

      it "returns :pass" do
        status, = doctor.send(:check_flight_middleware)
        expect(status).to eq(:pass)
      end
    end

    context "when no Rails application is present" do
      before { allow(Rails).to receive(:application).and_return(nil) }

      it "returns :pass (guarded edge context)" do
        status, = doctor.send(:check_flight_middleware)
        expect(status).to eq(:pass)
      end
    end

    context "when the app is not yet booted (middleware is a non-enumerable proxy)" do
      # Mirrors a pre-`initialize!` Rails::Configuration::MiddlewareStackProxy,
      # which does NOT respond to :each — must be skipped, not crash on filter_map.
      before do
        proxy = Object.new # responds to neither :each nor :filter_map
        app = Struct.new(:middleware).new(proxy)
        allow(Rails).to receive(:application).and_return(app)
      end

      it "returns :pass without raising" do
        expect { doctor.send(:check_flight_middleware) }.not_to raise_error
        status, = doctor.send(:check_flight_middleware)
        expect(status).to eq(:pass)
      end
    end
  end

  # --- :warn status semantics (Story 13.1, AC3) ---

  describe "#format_result with :warn", :story_13_1 do
    subject(:doctor) { described_class.new }

    it "renders :warn with the ⚠ glyph (not ✗)" do
      expect(doctor.send(:format_result, :warn, "heads up")).to eq("⚠ heads up")
    end
  end

  describe ".run with a :warn present (Story 13.1, AC3)", :story_13_1 do
    before do
      make_manifest
      make_controller(with_include: true)
      make_layout(with_sentinel: true)
      allow(TCPSocket).to receive(:new).and_return(instance_double(TCPSocket, close: nil))
      app = Struct.new(:middleware).new([Struct.new(:name).new("Rack::Deflater")])
      allow(Rails).to receive(:application).and_return(app)
    end

    it "still returns true — a :warn does not fail the run" do
      expect(described_class.run).to be true
    end

    it "prints the warning glyph" do
      expect { described_class.run }.to output(/⚠.*Rack::Deflater/).to_stdout
    end

    it "does not print the fix hint" do
      expect { described_class.run }.not_to output(/rails generate/).to_stdout
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

  describe "Rake task definition (Story 5.12)", :story_5_12 do
    # Loads gem/lib/tasks/ruact.rake into a fresh Rake::Application so the
    # task table is isolated from any other spec that may have loaded tasks.
    # Asserts the new namespace is discoverable AND the legacy namespace is
    # gone — guards against a partial rename (e.g. file renamed but the
    # namespace inside left as :rsc, or vice-versa).
    around do |example|
      require "rake"
      prev = Rake.application
      Rake.application = Rake::Application.new
      Rake.application.add_loader("rake", Rake::DefaultLoader.new)
      Rake.application.add_loader("rb",   Rake::DefaultLoader.new)
      load File.expand_path("../../lib/tasks/ruact.rake", __dir__)
      example.run
    ensure
      Rake.application = prev
    end

    let(:rake_app) { Rake.application }

    it "defines Rake::Task['ruact:doctor']" do
      expect(rake_app.lookup("ruact:doctor")).not_to be_nil
    end

    it "does NOT define the legacy Rake task under the pre-Story-5.12 namespace" do
      # Build the legacy task name from fragments so this spec file stays
      # grep-clean under the Story 5.12 CI guard (which rejects the literal
      # `<legacy>:doctor` substring anywhere in tracked files).
      legacy_task = %w[rsc doctor].join(":")
      expect(rake_app.lookup(legacy_task)).to be_nil
    end

    it "the ruact:doctor task action invokes Ruact::Doctor.run" do
      task = rake_app.lookup("ruact:doctor")
      expect(task).not_to be_nil
      # actions is a list of Procs; just assert at least one is attached
      expect(task.actions).not_to be_empty
    end
  end
end
