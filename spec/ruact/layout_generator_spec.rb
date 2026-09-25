# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"
require "stringio"
require "ruact"
require "generators/ruact/layout/layout_generator"

# Story 17.0b (AC4) — `rails generate ruact:layout` hands the app its own copy of
# the layout ruact pages render into. The app's copy wins over the gem's by
# view-path order (proven in gem_layout_boot_spec.rb), so no setting changes.
RSpec.describe Ruact::Generators::LayoutGenerator, :story_17_0b do # rubocop:disable RSpec/SpecFilePathFormat
  let(:app_root) { Dir.mktmpdir("ruact_layout_generator") }
  let(:destination) { File.join(app_root, "app/views/layouts/ruact.html.erb") }
  let(:shipped) { File.read(File.join(Ruact.views_path, "layouts/ruact.html.erb")) }

  after { FileUtils.rm_rf(app_root) }

  def run_generator(opts = {})
    original = $stdout
    $stdout = StringIO.new
    described_class.new([], opts, destination_root: app_root).invoke_all
    $stdout.string
  ensure
    $stdout = original
  end

  it "copies the shipped layout byte for byte — a copy, not a template" do
    run_generator

    expect(File.read(destination)).to eq(shipped)
  end

  it "says the ejected copy stops following the gem, and what must stay in it", :aggregate_failures do
    output = run_generator

    expect(output).to include("no longer change when you upgrade the gem")
    expect(output).to include("ruact_head_assets").and include("ruact_js_assets")
  end

  context "when the app already has layouts/ruact.html.erb" do
    before do
      FileUtils.mkdir_p(File.dirname(destination))
      File.write(destination, "<%# mine %>\n")
    end

    it "keeps the app's file under --skip" do
      run_generator(skip: true)

      expect(File.read(destination)).to eq("<%# mine %>\n")
    end

    it "replaces it only under --force" do
      run_generator(force: true)

      expect(File.read(destination)).to eq(shipped)
    end
  end
end
