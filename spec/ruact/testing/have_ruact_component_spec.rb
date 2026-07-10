# frozen_string_literal: true

require "spec_helper"
require "ruact/testing"

# Story 15.4 (FR108) — end-to-end specs for the PUBLIC render-assertion matcher
# `have_ruact_component`. Every example asserts against a REAL Flight wire body
# produced by `Ruact::RenderPipeline` (the same serializer the controller runs),
# not a hand-authored fixture — so import rows, `$L<id>` references, and the
# serialized props hash are exactly what a host would receive.
module Ruact
  RSpec.describe "have_ruact_component matcher", :story_15_4 do
    let(:manifest) do
      ClientManifest.from_hash({
                                 "LikeButton" => {
                                   "id" => "/assets/LikeButton-abc.js",
                                   "name" => "LikeButton",
                                   "chunks" => ["/assets/LikeButton-abc.js"]
                                 },
                                 "PostCard" => {
                                   "id" => "/components/PostCard.jsx",
                                   "name" => "PostCard",
                                   "chunks" => ["/components/PostCard.jsx"]
                                 }
                               })
    end

    let(:pipeline) { RenderPipeline.new(manifest) }

    # Renders an ERB snippet to a REAL Flight wire string.
    def render_wire(erb_source, **ivars)
      ctx = Object.new
      ivars.each { |k, v| ctx.instance_variable_set("@#{k}", v) }
      pipeline.render({ erb: erb_source, binding: ctx.instance_eval { binding } }, mode: :string)
    end

    # Wraps a wire in the REAL HTML shell the gem emits (`__FLIGHT_DATA` push),
    # via the shipped `Ruact::ViewHelper#ruact_flight_data_script`.
    def html_shell(wire)
      emitter = Object.new.extend(Ruact::ViewHelper)
      script = emitter.send(:ruact_flight_data_script, wire)
      "<!DOCTYPE html><html><body><div id=\"root\"></div>#{script}</body></html>"
    end

    # A minimal duck-typed response object exposing `.body` (+ optional
    # `.content_type`), like an ActionDispatch/Rack response.
    def response_double(body, content_type: nil)
      Struct.new(:body, :content_type).new(body, content_type)
    end

    describe "presence (raw text/x-component body)" do
      it "passes when the named component was rendered" do
        wire = render_wire("<LikeButton postId={42} />")
        expect(wire).to have_ruact_component("LikeButton")
      end

      it "resolves the name by module basename too (D3)" do
        wire = render_wire("<PostCard title={\"Hi\"} />")
        # Manifest module path is /components/PostCard.jsx → basename PostCard.
        expect(wire).to have_ruact_component("PostCard")
      end

      it "fails with a legible message naming what was found when absent" do
        wire = render_wire("<LikeButton />")
        expect do
          expect(wire).to have_ruact_component("Missing")
        end.to raise_error(RSpec::Expectations::ExpectationNotMetError,
                           /component named "Missing".*found.*LikeButton/m)
      end

      it "supports negation for an absent component" do
        wire = render_wire("<LikeButton />")
        expect(wire).not_to have_ruact_component("Missing")
      end

      it "negation fails legibly when the component IS present" do
        wire = render_wire("<LikeButton />")
        expect do
          expect(wire).not_to have_ruact_component("LikeButton")
        end.to raise_error(RSpec::Expectations::ExpectationNotMetError, /NOT to have rendered.*"LikeButton"/m)
      end
    end

    describe ".with_props (serialized wire form, D4)" do
      it "passes when props satisfy a hash_including matcher" do
        wire = render_wire("<LikeButton postId={42} />")
        expect(wire).to have_ruact_component("LikeButton").with_props(a_hash_including("postId" => 42))
      end

      it "passes with a bare key-presence include matcher" do
        wire = render_wire("<LikeButton postId={42} />")
        expect(wire).to have_ruact_component("LikeButton").with_props(including("postId"))
      end

      it "fails with a legible message when props mismatch" do
        wire = render_wire("<LikeButton postId={42} />")
        expect do
          expect(wire).to have_ruact_component("LikeButton").with_props(a_hash_including("postId" => 99))
        end.to raise_error(RSpec::Expectations::ExpectationNotMetError,
                           /props matching.*serialized wire form.*"postId".*42/m)
      end

      it "supports negation with props" do
        wire = render_wire("<LikeButton postId={42} />")
        expect(wire).not_to have_ruact_component("LikeButton").with_props(a_hash_including("postId" => 99))
      end
    end

    describe "input shapes (D2)" do
      it "accepts a response object exposing #body (raw wire)" do
        wire = render_wire("<LikeButton postId={7} />")
        response = response_double(wire, content_type: "text/x-component")
        expect(response).to have_ruact_component("LikeButton").with_props(a_hash_including("postId" => 7))
      end

      it "extracts Flight from an HTML shell embedding __FLIGHT_DATA" do
        wire = render_wire("<LikeButton postId={5} />")
        html = html_shell(wire)
        expect(html).to have_ruact_component("LikeButton").with_props(a_hash_including("postId" => 5))
      end

      it "extracts Flight from an HTML-response object (content_type text/html)" do
        wire = render_wire("<LikeButton postId={5} />")
        response = response_double(html_shell(wire), content_type: "text/html; charset=utf-8")
        expect(response).to have_ruact_component("LikeButton")
      end

      it "raises a clear error on a plain-JSON function-call body" do
        json = response_double(%({"id":1,"title":"Hi"}), content_type: "application/json")
        expect do
          expect(json).to have_ruact_component("PostCard")
        end.to raise_error(Ruact::Testing::NotAFlightResponseError, /plain-JSON response.*JSON\.parse/m)
      end

      it "raises a clear error on an empty (204) body" do
        empty = response_double("", content_type: nil)
        expect do
          expect(empty).to have_ruact_component("PostCard")
        end.to raise_error(Ruact::Testing::NotAFlightResponseError, /empty response body/m)
      end

      it "raises a clear error when handed an HTML doc with no Flight payload" do
        html = "<!DOCTYPE html><html><body><h1>Nothing here</h1></body></html>"
        expect do
          expect(html).to have_ruact_component("PostCard")
        end.to raise_error(Ruact::Testing::NotAFlightResponseError, /no `__FLIGHT_DATA` payload/m)
      end
    end

    describe "escape round-trip through the HTML shell" do
      it "recovers a payload containing quotes and interpolation-like sequences" do
        # Props whose serialized form contains characters Ruby's #inspect
        # escapes (`"`, `#{`, newlines) must survive extraction from the shell.
        wire = render_wire("<LikeButton label={@label} />", label: %(a "quoted" \#{literal}\nvalue))
        html = html_shell(wire)
        expect(html).to have_ruact_component("LikeButton")
          .with_props(a_hash_including("label" => a_string_matching(/quoted/)))
      end
    end
  end
end
