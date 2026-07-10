# frozen_string_literal: true

require "spec_helper"
require "rake"
require "json"
require "tmpdir"
require "action_controller"
require "ruact/server"
require "ruact/doctor"
require "ruact/server_functions"

# Story 15.3 (FR107) — end-to-end coverage of the `--json` Rake glue itself:
# the `-- --json` ARGV scan, JSON-only stdout (no human prose), and — for
# `ruact:doctor` — the preserved process exit code (0 pass/warn, 1 on fail).
# The `Doctor#as_json` / `Introspection.as_json` shapes are unit-tested
# elsewhere; THIS proves the task wiring around them (Codex R1, Acceptance
# Auditor). Mirrors the isolated-Rake harness in
# spec/ruact/server_functions/rake_spec.rb.
module Ruact
  RSpec.describe "rake --json introspection tasks", :story_15_3 do
    around do |example|
      Dir.mktmpdir do |dir|
        original_root = Rails.root
        Rails.root = Pathname.new(dir)

        prev = Rake.application
        Rake.application = Rake::Application.new
        Rake.application.define_task(Rake::Task, :environment)
        load File.expand_path("../../lib/tasks/ruact.rake", __dir__)

        example.run
      ensure
        Rake.application = prev
        Rails.root = original_root
      end
    end

    def invoke!(task_name)
      Rake::Task[task_name].reenable
      Rake::Task[task_name].invoke
    end

    # ---- ruact:doctor -- --json (AC1: JSON-only stdout + preserved exit) ----

    describe "ruact:doctor -- --json" do
      before { stub_const("ARGV", %w[ruact:doctor -- --json]) }

      def stub_doctor(status:)
        report = {
          "schema_version" => 0,
          "status" => status,
          "checks" => [{ "name" => "manifest", "status" => status, "message" => "m", "remediation" => nil }]
        }
        allow(Ruact::Doctor).to receive(:new).and_return(instance_double(Ruact::Doctor, as_json: report))
      end

      it "prints ONLY the JSON document (no prose) and does not exit when all pass", :aggregate_failures do
        stub_doctor(status: "pass")

        out = nil
        expect { out = capture_stdout_string { invoke!("ruact:doctor") } }.not_to raise_error
        parsed = JSON.parse(out)
        expect(parsed["schema_version"]).to eq(0)
        expect(parsed["status"]).to eq("pass")
        expect(out).not_to include("[ruact] Health check")
        expect(out).not_to include("Run rails generate")
      end

      it "exits 1 (SystemExit) when a check fails, still emitting the JSON", :aggregate_failures do
        stub_doctor(status: "fail")

        expect do
          expect { invoke!("ruact:doctor") }.to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
        end.to output(/"status": "fail"/).to_stdout
      end
    end

    it "ruact:doctor WITHOUT --json runs the human path (no JSON), returns 0 when healthy" do
      stub_const("ARGV", %w[ruact:doctor])
      allow(Ruact::Doctor).to receive(:run).and_return(true)

      expect { expect { invoke!("ruact:doctor") }.not_to raise_error }.not_to output(/schema_version/).to_stdout
      expect(Ruact::Doctor).to have_received(:run)
    end

    # ---- ruact:routes (AC2: JSON via -- --json, human table bare) ----

    describe "ruact:routes" do
      before do
        stub_const("RakeRoutesPostsController", Class.new(ActionController::Base) { include Ruact::Server })
        reloader = Object.new
        def reloader.execute_unless_loaded; end
        rs = ActionDispatch::Routing::RouteSet.new
        rs.draw { resources :rake_routes_posts, only: %i[create] }
        app = Object.new
        app.define_singleton_method(:routes) { rs }
        app.define_singleton_method(:routes_reloader) { reloader }
        allow(Rails).to receive(:application).and_return(app)
      end

      it "emits the EXPERIMENTAL JSON document under -- --json (end-to-end, real resolvers)", :aggregate_failures do
        stub_const("ARGV", %w[ruact:routes -- --json])

        out = capture_stdout_string { invoke!("ruact:routes") }
        parsed = JSON.parse(out)
        expect(parsed["schema_version"]).to eq(0)
        create = parsed["accessors"].find { |a| a["accessor"] == "createRakeRoutesPost" }
        expect(create).to include("kind" => "action", "verb" => "POST", "path" => "/rake_routes_posts")
      end

      it "prints a compact human table (no JSON) when invoked bare", :aggregate_failures do
        stub_const("ARGV", %w[ruact:routes])

        out = capture_stdout_string { invoke!("ruact:routes") }
        expect(out).to include("server-function accessors:")
        expect(out).to include("createRakeRoutesPost")
        expect(out).not_to include("schema_version")
      end

      it "exits 1 with a `[ruact] error:` line on a naming collision" do
        stub_const("ARGV", %w[ruact:routes -- --json])
        allow(Ruact::ServerFunctions).to receive(:introspect)
          .and_raise(Ruact::ConfigurationError, "server-function naming collision: A#x and B#x ...")

        expect { invoke!("ruact:routes") }
          .to raise_error(SystemExit)
          .and output(/\[ruact\] error:.*naming collision/).to_stderr
      end
    end

    # Captures $stdout into a String (the harness has no shared helper).
    def capture_stdout_string
      original = $stdout
      $stdout = StringIO.new
      yield
      $stdout.string
    ensure
      $stdout = original
    end
  end
end
