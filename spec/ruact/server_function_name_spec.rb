# frozen_string_literal: true

require "spec_helper"
require "ruact/server"

# Story 9.3 AC4 — the `ruact_function_name` rename-override macro. Tested via
# the concern's ClassMethods in isolation (no ActionController boot needed) so
# the validation + storage contract is pinned independently of the request
# cycle. RouteSource consumes the resulting `__ruact_function_name_overrides`.
RSpec.describe "Ruact::Server.ruact_function_name", :story_9_3 do
  subject(:host) { Class.new { extend Ruact::Server::ClassMethods } }

  it "stores the override keyed by action name (string)" do
    host.ruact_function_name(:publish_all, as: "publishEverything")
    expect(host.__ruact_function_name_overrides).to eq("publish_all" => "publishEverything")
  end

  it "accepts a symbol target and stringifies it" do
    host.ruact_function_name(:publish_all, as: :publishEverything)
    expect(host.__ruact_function_name_overrides.fetch("publish_all")).to eq("publishEverything")
  end

  it "starts empty and is per-class (not shared)" do
    other = Class.new { extend Ruact::Server::ClassMethods }
    host.ruact_function_name(:create, as: "makePost")
    expect(host.__ruact_function_name_overrides).to eq("create" => "makePost")
    expect(other.__ruact_function_name_overrides).to eq({})
  end

  it "rejects an invalid JS identifier at class-load time" do
    expect do
      host.ruact_function_name(:create, as: "2bad name")
    end.to raise_error(Ruact::ConfigurationError, /not a valid JS identifier/)
  end

  it "rejects a reserved JS word" do
    expect do
      host.ruact_function_name(:create, as: "class")
    end.to raise_error(Ruact::ConfigurationError, /reserved/)
  end

  it "rejects a runtime-bound name (revalidate / _makeRef)" do
    expect do
      host.ruact_function_name(:create, as: "revalidate")
    end.to raise_error(Ruact::ConfigurationError, /reserved|ruact runtime/)
  end

  it "rejects the v2 runtime accessor name (_makeServerFunction)" do
    expect do
      host.ruact_function_name(:create, as: "_makeServerFunction")
    end.to raise_error(Ruact::ConfigurationError, /reserved|ruact runtime/)
  end
end
