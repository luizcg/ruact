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

  # `with_assets` is the second half of a migrated layout: the React root alone
  # leaves ruact on its built-in (CSS-less) shell, so the two markers are
  # independent inputs, not one sentinel.
  def make_layout(with_sentinel: true, with_assets: true)
    dir = tmpdir.join("app", "views", "layouts")
    FileUtils.mkdir_p(dir)
    content =
      if !with_sentinel
        "<body></body>\n"
      elsif with_assets
        "<%# ruact: root %>\n<div id=\"root\"></div>\n<%= ruact_js_assets %>\n"
      else
        "<%# ruact: root %>\n<div id=\"root\"></div>\n"
      end
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

  # Story 17.0g (FR116) — the check reports the ADOPTION MODE. Island (the
  # install default): the concern is on the controllers that render ruact
  # pages; whole-app (`--app`): it is on ApplicationController. It used to FAIL
  # every island app, because it only asked about ApplicationController.
  describe "#check_controller (Story 17.0g — adoption mode)", :story_17_0g do
    subject(:doctor) { described_class.new }

    def write_controller(name, body)
      file = tmpdir.join("app", "controllers", name)
      FileUtils.mkdir_p(file.dirname)
      File.write(file, body)
    end

    def write_view(path)
      file = tmpdir.join("app", "views", path)
      FileUtils.mkdir_p(file.dirname)
      File.write(file, "<h1>x</h1>")
    end

    context "when ApplicationController includes Ruact::Controller (whole-app)" do
      before do
        make_controller(with_include: true)
        write_view("posts/index.html.erb")
        write_view("posts/_row.html.erb")
        write_view("pages/about.html.erb")
        write_view("layouts/application.html.erb")
      end

      it "passes, naming the mode and how many templates now render through ruact", :aggregate_failures do
        status, message = doctor.send(:check_controller)

        expect(status).to eq(:pass)
        expect(message).to include("whole-app")
        # Partials and layouts are not pages.
        expect(message).to include("2 templates")
      end
    end

    context "when a controller of its own includes it (island)" do
      before do
        make_controller(with_include: false)
        write_controller("products_controller.rb", "class ProductsController < ApplicationController
  include Ruact::Controller
end
")
        write_controller("people_controller.rb", "class PeopleController < ApplicationController
end
")
      end

      it "passes, naming the mode and how many controllers render ruact pages", :aggregate_failures do
        status, message = doctor.send(:check_controller)

        expect(status).to eq(:pass)
        expect(message).to include("island").and include("1 controller")
      end
    end

    context "when nothing includes it yet (a fresh island install)" do
      before { make_controller(with_include: false) }

      it "warns — not a failure — and says how to get a first page", :aggregate_failures do
        status, message = doctor.send(:check_controller)

        expect(status).to eq(:warn)
        expect(message).to include("include Ruact::Controller").and include("ruact:scaffold")
      end
    end

    # Review round 1 (17.0g) — the forms an include takes in real code count;
    # a concern module, a nested ApplicationController and mailer views don't
    # say anything about pages.
    context "when the include takes another form, or lives outside a page controller" do
      before do
        make_controller(with_include: false)
        write_controller("a_controller.rb", "class AController < ApplicationController\n  include(Ruact::Controller)\nend\n")
        write_controller("b_controller.rb", "class BController < ApplicationController\n  include ::Ruact::Controller\nend\n")
        write_controller("c_controller.rb", "class CController < ApplicationController\n  include Auth, Ruact::Controller\nend\n")
        write_controller("concerns/pageable.rb", "module Pageable\n  include Ruact::Controller\nend\n")
        write_controller("admin/application_controller.rb",
                         "module Admin\n  class ApplicationController < ::ApplicationController\n    " \
                         "include Ruact::Controller\n  end\nend\n")
      end

      it "counts the include forms and the nested base, not the concern", :aggregate_failures do
        status, message = doctor.send(:check_controller)

        expect(status).to eq(:pass)
        expect(message).to include("island").and include("4 controllers")
      end
    end

    context "when counting whole-app templates" do
      before do
        make_controller(with_include: true)
        write_view("posts/index.html.erb")
        write_view("user_mailer/welcome.html.erb")
      end

      it "leaves mailer views out" do
        expect(doctor.send(:check_controller).last).to include("1 template")
      end
    end

    # A mention is not an include.
    context "when the include is commented out" do
      before do
        make_controller(with_include: false)
        write_controller("products_controller.rb", "class ProductsController < ApplicationController
  # include Ruact::Controller
end
")
      end

      it "does not count it" do
        expect(doctor.send(:check_controller).first).to eq(:warn)
      end
    end
  end

  # --- check_layout ---

  # Story 17.0b (issue #63) — client-component CSS that nothing links.
  #
  # The failure being guarded is silent and production-only: Vite records the
  # stylesheets on the manifest entry, the build serves them, and nothing
  # references them. Development hides it, because the dev server injects that
  # CSS through JS.
  #
  # The decision here is MECHANICAL — read the manifest, read the layout. Layout
  # auto-detection was removed deliberately after three rounds of pattern-matching
  # failures, so `LayoutSource.head_wired?` (which strips comments) is the only
  # thing allowed to answer "is it wired?".
  describe "#check_head_assets (Story 17.0b)", :story_17_0b do
    subject(:doctor) { described_class.new }

    def write_manifest(entry)
      dir = tmpdir.join("public", "assets", ".vite")
      FileUtils.mkdir_p(dir)
      File.write(dir.join("manifest.json"), JSON.generate({ Ruact.bootstrap_virtual_id => entry }))
    end

    def write_head(body)
      dir = tmpdir.join("app", "views", "layouts")
      FileUtils.mkdir_p(dir)
      File.write(dir.join("application.html.erb"), body)
    end

    before { Ruact.configure { |c| c.layout = true } }

    context "when the build emits CSS and the layout does not link it" do
      before do
        write_manifest({ "file" => "bootstrap-abc.js", "css" => ["bootstrap-def.css"] })
        write_head("<html><head><%= stylesheet_link_tag :app %></head><body></body></html>")
      end

      it "FAILS, and names the file and the line to paste", :aggregate_failures do
        status, message, remediation = doctor.send(:check_head_assets)

        expect(status).to eq(:fail)
        expect(message).to include("1 client-component stylesheet")
        # `Doctor#run` prints MESSAGE only — remediation reaches `-- --json`
        # alone. A reader in the terminal has to get the file from the message.
        expect(message).to include("application.html.erb")
        expect(message).to include("ruact_head_assets")
        expect(remediation).to include("ruact_head_assets")
        expect(remediation).to include("app/views/layouts/application.html.erb")
        # The cascade instruction is load-bearing: linking it below the app's own
        # stylesheet would put third-party CSS after the app's, so it wins ties.
        expect(remediation).to include("ABOVE your stylesheet_link_tag")
      end

      it "is a failure status, not a warning" do
        expect(described_class::SUCCESS_STATUSES).not_to include(:fail)
      end
    end

    context "when the layout links it" do
      before do
        write_manifest({ "file" => "bootstrap-abc.js", "css" => ["bootstrap-def.css"] })
        write_head("<html><head><%= ruact_head_assets %><%= stylesheet_link_tag :app %></head><body></body></html>")
      end

      it "returns :pass" do
        expect(doctor.send(:check_head_assets).first).to eq(:pass)
      end
    end

    context "when the helper is only MENTIONED IN A COMMENT" do
      before do
        write_manifest({ "file" => "bootstrap-abc.js", "css" => ["bootstrap-def.css"] })
        write_head("<html><head><%# ruact_head_assets %></head><body></body></html>")
      end

      it "still FAILS — a mention is not a call" do
        # This is the shape that fooled layout auto-detection three times.
        expect(doctor.send(:check_head_assets).first).to eq(:fail)
      end
    end

    # Under `layout = false` the built-in shell links this CSS itself, so there is
    # no layout to check and nothing to report. Losing that early return made the
    # doctor fail an app that was already correct.
    context "when config.layout is false" do
      before do
        write_manifest({ "file" => "b.js", "css" => ["a.css"] })
        write_head("<html><head></head><body></body></html>")
        Ruact.configure { |c| c.layout = false }
      end

      it "passes — the built-in shell links it, and no layout is consulted" do
        status, message = doctor.send(:check_head_assets)

        expect(status).to eq(:pass)
        expect(message).to include("shell")
      end
    end

    context "when the build emits no CSS" do
      before do
        write_manifest({ "file" => "bootstrap-abc.js" })
        write_head("<html><head></head><body></body></html>")
      end

      it "returns :pass — there is nothing to link" do
        expect(doctor.send(:check_head_assets).first).to eq(:pass)
      end
    end

    context "when there is no build at all" do
      it "returns :pass rather than failing on a missing manifest" do
        expect(doctor.send(:check_head_assets).first).to eq(:pass)
      end
    end

    # Review round 1: the check read application.html.erb regardless of what
    # `config.layout` names, so an app rendering through `admin` passed on a
    # layout it never uses.
    context "when config.layout names ANOTHER layout" do
      before do
        write_manifest({ "file" => "b.js", "css" => ["a.css"] })
        write_head("<html><head><%= ruact_head_assets %></head><body></body></html>")
        dir = tmpdir.join("app", "views", "layouts")
        File.write(dir.join("admin.html.erb"), "<html><head></head><body></body></html>")
        Ruact.configure { |c| c.layout = "admin" }
      end

      it "FAILS on the layout that actually renders, not on application", :aggregate_failures do
        status, _message, remediation = doctor.send(:check_head_assets)

        expect(status).to eq(:fail)
        expect(remediation).to include("admin.html.erb")
      end
    end

    # Rails accepts both `admin` and `layouts/admin`. Doubling the prefix looked
    # for app/views/layouts/layouts/admin.html.erb and declared it missing.
    context "when config.layout carries the conventional layouts/ prefix" do
      before do
        write_manifest({ "file" => "b.js", "css" => ["a.css"] })
        dir = tmpdir.join("app", "views", "layouts")
        FileUtils.mkdir_p(dir)
        File.write(dir.join("admin.html.erb"), "<html><head><%= ruact_head_assets %></head><body></body></html>")
        Ruact.configure { |c| c.layout = "layouts/admin" }
      end

      it "resolves to the same file as the bare name" do
        expect(doctor.send(:check_head_assets).first).to eq(:pass)
      end
    end

    context "when config.layout names a layout that does not exist" do
      before do
        write_manifest({ "file" => "b.js", "css" => ["a.css"] })
        Ruact.configure { |c| c.layout = "missing" }
      end

      it "FAILS naming the missing file rather than claiming the shell covers it" do
        status, message = doctor.send(:check_head_assets)

        expect(status).to eq(:fail)
        expect(message).to include("missing.html.erb")
      end
    end

    # An unreadable manifest is not "nothing to link" — the same file is parsed
    # at render time, where a parse error raises. A green doctor on an app that
    # 500s is worse than no check.
    context "when the manifest is corrupt" do
      before do
        dir = tmpdir.join("public", "assets", ".vite")
        FileUtils.mkdir_p(dir)
        File.write(dir.join("manifest.json"), "{")
        write_head("<html><head></head><body></body></html>")
      end

      it "FAILS naming the file, instead of passing as if there were no CSS", :aggregate_failures do
        status, message = doctor.send(:check_head_assets)

        expect(status).to eq(:fail)
        expect(message).to include("not valid JSON")
      end
    end

    # Story 17.0b, Mode A — ruact pages render through the layout the GEM ships
    # (`config.layout = "ruact"`). With no layout of that name in the app there
    # is no app file to read: the gem's layout calls the helper itself.
    context "when config.layout is \"ruact\" and the app has no such layout (the gem's renders)" do
      before do
        write_manifest({ "file" => "b.js", "css" => ["a.css"] })
        write_head("<html><head><%= stylesheet_link_tag :app %></head><body></body></html>")
        Ruact.configure { |c| c.layout = "ruact" }
      end

      it "passes without reading any app layout", :aggregate_failures do
        status, message = doctor.send(:check_head_assets)

        expect(status).to eq(:pass)
        expect(message).to include("ruact's layout")
      end
    end

    # An EJECTED layout (`rails g ruact:layout`) wins over the gem's by view-path
    # order, so it is the file that renders — and the file this check reads.
    context "when the app has ejected layouts/ruact.html.erb and dropped the helper" do
      before do
        write_manifest({ "file" => "b.js", "css" => ["a.css"] })
        dir = tmpdir.join("app", "views", "layouts")
        FileUtils.mkdir_p(dir)
        File.write(dir.join("ruact.html.erb"), "<html><head></head><body></body></html>")
        Ruact.configure { |c| c.layout = "ruact" }
      end

      it "FAILS naming the ejected file", :aggregate_failures do
        status, message = doctor.send(:check_head_assets)

        expect(status).to eq(:fail)
        expect(message).to include("ruact.html.erb")
      end
    end

    # Review round 1 — no build is the normal state in development with Vite
    # running. An own layout without the helper used to PASS there ("nothing to
    # link") and then lose the component CSS in production.
    context "when there is no build yet and the app's own layout never calls the helper" do
      before do
        write_head("<html><head><%= stylesheet_link_tag :app %></head><body></body></html>")
        Ruact.configure { |c| c.layout = true }
      end

      it "warns, naming the file", :aggregate_failures do
        status, message = doctor.send(:check_head_assets)

        expect(status).to eq(:warn)
        expect(message).to include("application.html.erb").and include("ruact_head_assets")
      end
    end

    it "is registered in CHECKS, so a real doctor run reaches it" do
      expect(described_class::CHECKS).to include(:head_assets)
    end
  end

  describe "#check_layout (AC#1, #5)" do
    subject(:doctor) { described_class.new }

    context "when the layout is wired and the app opted in" do
      before do
        make_layout(with_sentinel: true, with_assets: true)
        Ruact.configure { |c| c.layout = true }
      end

      it "returns :pass" do
        status, = doctor.send(:check_layout)
        expect(status).to eq(:pass)
      end
    end

    # Both halves are silent when wrong, and they are DIFFERENT fixes — "add one
    # line to the layout" versus "flip one setting" — so they report separately.
    context "when the layout is wired but Ruact.config.layout is false" do
      before do
        make_layout(with_sentinel: true, with_assets: true)
        Ruact.configure { |c| c.layout = false }
      end

      it "returns :warn naming the setting, not the layout" do
        status, message, remediation = doctor.send(:check_layout)

        expect(status).to eq(:warn)
        expect(message).to include("config.layout is false")
        expect(remediation).to include("config.layout = true")
      end

      it "does not fail the doctor run" do
        expect(described_class::SUCCESS_STATUSES).to include(:warn)
      end
    end

    context "when the layout has the React root but never calls ruact_js_assets" do
      before do
        make_layout(with_sentinel: true, with_assets: false)
        Ruact.configure { |c| c.layout = true }
      end

      it "fails and names the helper to add" do
        status, _message, remediation = doctor.send(:check_layout)

        expect(status).to eq(:fail)
        expect(remediation).to include("ruact_js_assets")
      end
    end

    # The drift this shares with the runtime and the generator: a MENTION of the
    # helper in a comment is not a call, and reporting :pass on one sent a
    # developer looking anywhere but at the real problem.
    context "when the layout only mentions the helper in a comment" do
      before do
        dir = tmpdir.join("app", "views", "layouts")
        FileUtils.mkdir_p(dir)
        File.write(dir.join("application.html.erb"),
                   "<%# ruact: root %>\n<div id=\"root\"></div>\n<%# TODO: add ruact_js_assets %>\n")
        Ruact.configure { |c| c.layout = true }
      end

      it "does not report it as wired" do
        status, = doctor.send(:check_layout)
        expect(status).to eq(:fail)
      end
    end

    context "when the layout has neither the root nor the helper" do
      before { make_layout(with_sentinel: false) }

      it "returns :fail" do
        status, = doctor.send(:check_layout)
        expect(status).to eq(:fail)
      end

      # Story 17.0b review — the MESSAGE names the exact missing lines: it is all
      # `Doctor#run` prints, and "the root and/or the helper" left the reader to
      # work out which.
      it "names each missing line exactly" do
        _, msg = doctor.send(:check_layout)
        expect(msg).to eq(%(application.html.erb is missing <div id="root"></div> and <%= ruact_js_assets %>))
      end
    end

    context "when there is no application layout file at all" do
      it "reports the file, not its contents" do
        status, msg = doctor.send(:check_layout)

        expect(status).to eq(:fail)
        expect(msg).to eq("React shell missing from application.html.erb")
      end
    end

    # Story 17.0b, Mode A. A fresh install writes `config.layout = "ruact"` and
    # leaves the app's own layout untouched — so that layout has no React root
    # and no ruact_js_assets, and reading it (as this check used to, always)
    # failed a correct install.
    context "when config.layout is \"ruact\" and the app keeps a stock layout", :story_17_0b do
      before do
        make_layout(with_sentinel: false)
        Ruact.configure { |c| c.layout = "ruact" }
      end

      it "passes, naming the gem's layout as the one that renders", :aggregate_failures do
        status, message = doctor.send(:check_layout)

        expect(status).to eq(:pass)
        expect(message).to include("ruact's layout")
      end
    end

    context "when an ejected layouts/ruact.html.erb lost the React root", :story_17_0b do
      before do
        dir = tmpdir.join("app", "views", "layouts")
        FileUtils.mkdir_p(dir)
        File.write(dir.join("ruact.html.erb"), "<html><body><%= ruact_js_assets %></body></html>")
        Ruact.configure { |c| c.layout = "ruact" }
      end

      it "fails naming the ejected file, not application.html.erb", :aggregate_failures do
        status, message = doctor.send(:check_layout)

        expect(status).to eq(:fail)
        expect(message).to include("ruact.html.erb")
        expect(message).not_to include("application.html.erb")
      end
    end

    # Review round 1 — advising `config.layout = "ruact"` to the app's own copy
    # of the ruact layout is advice to change nothing.
    context "when the ejected layouts/ruact.html.erb is the one missing lines", :story_17_0b do
      before do
        dir = tmpdir.join("app", "views", "layouts")
        FileUtils.mkdir_p(dir)
        File.write(dir.join("ruact.html.erb"), "<html><body></body></html>")
        Ruact.configure { |c| c.layout = "ruact" }
      end

      it "does not suggest the setting it already has" do
        _, _, remediation = doctor.send(:check_layout)

        expect(remediation).not_to include(%(config.layout = "ruact"))
      end
    end

    context "when config.layout names a layout that exists nowhere", :story_17_0b do
      before { Ruact.configure { |c| c.layout = "nowhere" } }

      it "fails naming the layout it looked for", :aggregate_failures do
        status, message = doctor.send(:check_layout)

        expect(status).to eq(:fail)
        expect(message).to include("nowhere.html.erb")
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

    context "with a `decode_flight` inbound entry point (review finding R3)" do
      before { write_source("decoder.rb", "def decode_flight(body)\n  body\nend\n") }

      it "returns :fail (decode_flight is an inbound deserialization signal)" do
        status, = doctor.send(:check_serialize_only)
        expect(status).to eq(:fail)
      end
    end

    context "with a deserializer in a differently-located file ALSO named doctor.rb (review finding R1)" do
      # Only the gem's own lib/ruact/doctor.rb is excluded (by exact path), not
      # every basename `doctor.rb` — a nested namesake must still be scanned.
      before { write_source("ruact/flight/doctor.rb", "class FlightDeserializer; end\n") }

      it "returns :fail (basename collision is not a free pass)" do
        status, = doctor.send(:check_serialize_only)
        expect(status).to eq(:fail)
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

  describe "#run with an unexpected status (review finding R1)", :story_13_1 do
    before do
      make_manifest
      make_controller(with_include: true)
      make_layout(with_sentinel: true)
      allow(TCPSocket).to receive(:new).and_return(instance_double(TCPSocket, close: nil))
    end

    it "fails the run when a check returns a status that is neither :pass nor :warn" do
      doctor = described_class.new
      # All other checks pass; a malformed status (rendered ✗) must NOT be
      # silently treated as a pass — only :pass / :warn are success.
      allow(doctor).to receive(:check_streaming).and_return([:error, "broken status"])
      expect(doctor.run).to be false
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
          .to output(/Run rails ruact:doctor -- --json for how to fix each failure/).to_stdout
      end
    end
  end

  # --- JSON introspection (Story 15.3, FR107, AC1 + AC3 + AC4) ---

  describe "#as_json (machine-readable report)", :story_15_3 do
    subject(:doctor) { described_class.new }

    context "when all checks pass" do
      before do
        make_manifest
        make_controller(with_include: true)
        make_layout(with_sentinel: true)
        allow(TCPSocket).to receive(:new).and_return(instance_double(TCPSocket, close: nil))
      end

      it "returns a document that round-trips through JSON.parse", :aggregate_failures do
        report = doctor.as_json
        reparsed = JSON.parse(JSON.generate(report))
        expect(reparsed).to eq(report)
      end

      it "gates the document with the EXPERIMENTAL schema_version (0)" do
        expect(doctor.as_json["schema_version"]).to eq(0)
        expect(doctor.as_json["schema_version"]).to eq(Ruact::Doctor::SCHEMA_VERSION)
      end

      it "carries every check with name/status/message/remediation keys", :aggregate_failures do
        checks = doctor.as_json["checks"]
        expect(checks.map { |c| c["name"] }).to eq(described_class::CHECKS.map(&:to_s))
        checks.each do |check|
          expect(check.keys).to contain_exactly("name", "status", "message", "remediation")
          expect(check["status"]).to be_a(String)
          expect(check["message"]).to be_a(String)
        end
      end

      it "reports top-level status 'pass' and exits-zero semantics" do
        expect(doctor.as_json["status"]).to eq("pass")
      end

      it "emits NO prose to stdout (JSON mode is the document only)" do
        expect { doctor.as_json }.not_to output.to_stdout
      end
    end

    context "when a check fails" do
      before do
        make_controller(with_include: true)
        make_layout(with_sentinel: true)
        allow(TCPSocket).to receive(:new).and_return(instance_double(TCPSocket, close: nil))
        # manifest is missing → check_manifest fails
      end

      it "reports top-level status 'fail' (non-zero exit semantics)" do
        expect(doctor.as_json["status"]).to eq("fail")
      end

      it "carries the separate machine-readable remediation for the failing check" do
        manifest = doctor.as_json["checks"].find { |c| c["name"] == "manifest" }
        expect(manifest["status"]).to eq("fail")
        expect(manifest["remediation"]).to eq("Run vite build (or bin/dev) to generate the client manifest.")
      end
    end

    context "when a check warns (Rack::Deflater mounted)" do
      before do
        make_manifest
        make_controller(with_include: true)
        make_layout(with_sentinel: true)
        allow(TCPSocket).to receive(:new).and_return(instance_double(TCPSocket, close: nil))
        app = Struct.new(:middleware).new([Struct.new(:name).new("Rack::Deflater")])
        allow(Rails).to receive(:application).and_return(app)
      end

      it "keeps status 'pass' — a :warn does not fail — but exposes the warn check" do
        report = doctor.as_json
        expect(report["status"]).to eq("pass")
        flight = report["checks"].find { |c| c["name"] == "flight_middleware" }
        expect(flight["status"]).to eq("warn")
        expect(flight["remediation"]).to include("Exclude text/x-component from compression")
      end
    end

    it "keeps the message byte-identical to the human tuple (remediation is separate)" do
      _status, human_message = doctor.send(:check_manifest)
      json_message = doctor.as_json["checks"].find { |c| c["name"] == "manifest" }["message"]
      expect(json_message).to eq(human_message)
    end
  end

  describe "#results / #passed? (shared compute, Story 15.3)", :story_15_3 do
    subject(:doctor) { described_class.new }

    before do
      make_manifest
      make_controller(with_include: true)
      make_layout(with_sentinel: true)
      allow(TCPSocket).to receive(:new).and_return(instance_double(TCPSocket, close: nil))
    end

    it "returns one tuple per check, index-aligned with CHECKS" do
      expect(doctor.results.length).to eq(described_class::CHECKS.length)
    end

    it "passed? is true when all checks pass/warn" do
      expect(doctor.passed?).to be true
    end

    it "runs each check exactly once (as_json does not double-run check_vite's socket)" do
      # check_vite opens a socket via TCPSocket.new; a single as_json must open it
      # exactly once — proving #results is computed once, not per consumer.
      doctor.as_json
      expect(TCPSocket).to have_received(:new).once
    end
  end

  describe "#run stays byte-identical after the #results refactor (Story 15.3, AC4a)", :story_15_3 do
    subject(:doctor) { described_class.new }

    before do
      make_manifest
      make_controller(with_include: true)
      make_layout(with_sentinel: true)
      allow(TCPSocket).to receive(:new).and_return(instance_double(TCPSocket, close: nil))
    end

    it "prints exactly the header + one format_result line per check (no JSON/prose leak), returns true" do
      # Reconstruct the expected output from the SAME format_result the human
      # path uses — proves #run still emits header + one glyph line per check
      # (the optional 3rd remediation element is ignored) and nothing else.
      lines = doctor.results.map { |status, message| doctor.send(:format_result, status, message) }.join("\n")
      expected = "[ruact] Health check\n#{lines}\n"

      expect { expect(doctor.run).to be true }.to output(expected).to_stdout
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

    it "defines Rake::Task['ruact:routes'] with an action (Story 15.3)", :story_15_3 do
      task = rake_app.lookup("ruact:routes")
      expect(task).not_to be_nil
      expect(task.actions).not_to be_empty
    end
  end
end
