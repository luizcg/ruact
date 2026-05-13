# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

# Spec_helper's rails_stub defines Rails; the railtie was not auto-required
# because Rails was not yet defined when ruact.rb evaluated `require_relative
# "ruact/railtie" if defined?(Rails)`. Load it explicitly (mirrors
# spec/ruact/railtie_spec.rb).
require "ruact/railtie"

# Story 8.0a — Railtie.write_server_functions_snapshot! is the entry point
# wired into `config.to_prepare`. The full to_prepare boot lives in
# controller_request_spec.rb; here we exercise the class method directly with
# Rails.root pointed at a tmpdir, which is enough to validate the contract
# (Story 8.0a Task 2.6 — Railtie path resolution + write-if-changed).
module Ruact
  module ServerFunctions
    RSpec.describe "Ruact::Railtie.write_server_functions_snapshot!", :story_8_0a do
      around do |example|
        Dir.mktmpdir do |dir|
          original_root = Rails.root
          Rails.root    = Pathname.new(dir)
          @tmpdir       = dir
          example.run
        ensure
          Rails.root = original_root
        end
      end

      let(:path) { File.join(@tmpdir, "tmp/cache/ruact/server-functions.json") }

      it "writes the JSON to tmp/cache/ruact/server-functions.json (Story 8.0a)" do
        result = Ruact::Railtie.write_server_functions_snapshot!
        expect(result).to be(true)
        expect(File).to exist(path)
      end

      it "writes an empty `functions: []` array when both registries are empty " \
         "(Story 8.0a — empty-registry contract)" do
        Ruact::Railtie.write_server_functions_snapshot!
        parsed = JSON.parse(File.read(path))
        expect(parsed.fetch("functions")).to eq([])
      end

      it "the file is short-circuited on a second call with an unchanged registry " \
         "(Story 8.0a — pitfall #1)" do
        Ruact::Railtie.write_server_functions_snapshot!
        expect(Ruact::Railtie.write_server_functions_snapshot!).to be(false)
      end

      it "rewrites the file after a registration is added (Story 8.0a)" do
        Ruact::Railtie.write_server_functions_snapshot!
        Ruact.action_registry.register(:demo_ping, kind: :action)

        expect(Ruact::Railtie.write_server_functions_snapshot!).to be(true)
        parsed = JSON.parse(File.read(path))
        expect(parsed["functions"].map { |fn| fn["ruby_symbol"] }).to eq(["demo_ping"])
      end
    end
  end
end
