# frozen_string_literal: true

require "spec_helper"
require "net/protocol"

# Story 19-1 — the render of a page whose <Suspense> blocks run after the shell,
# without a controller: a view that captures what a block writes, a manifest
# that knows some components.
RSpec.describe Ruact::DeferredRender do
  let(:context) { Ruact::RenderContext.new(deferring: true) }
  let(:view) do
    Class.new do
      attr_reader :out

      def capture
        @out = +""
        yield
        @out
      end
    end.new
  end
  let(:manifest) do
    Class.new do
      def reference_for(name, **)
        raise Ruact::ManifestError, "unknown #{name}" if name == "Missing"

        Ruact::Flight::ClientReference.new(module_id: "/#{name}.js", export_name: name)
      end

      def resolve(module_id, export_name) = [module_id, [], export_name]
    end.new
  end
  let(:pipeline) { Ruact::RenderPipeline.new(manifest) }

  # A <Suspense> whose block writes +html+ (a String, or a lambda that gets the
  # context and the view and returns one).
  def boundary(html)
    write = html.respond_to?(:call) ? html : ->(*) { html }
    block = -> { view.out << write.call(context, view) }
    index = context.defer_block(Ruact::RenderContext::Block.new(view, block, "pages/show", nil, nil))
    "#{Ruact::Markers.suspense_open('loading', nil, block: index)}#{Ruact::Markers::SUSPENSE_CLOSE}"
  end

  def component(name)
    ->(ctx, _view) { Ruact::Markers.component(ctx.register(name, {})) }
  end

  def run(*boundaries)
    render = described_class.new("<main>#{boundaries.join}</main>", context, pipeline)
    render.shell
    Array.new(boundaries.length) { render.next_rows }
  end

  it "renders each block after the shell, with the components it registers", :aggregate_failures do
    rows = run(boundary("<p>first</p>"), boundary(component("Good")))
    expect(rows[0]).to include('"children":"first"')
    expect(rows[1]).to include("/Good.js")
  end

  # Review R1 — a component the manifest cannot resolve fails its own boundary,
  # not every one after it.
  it "fails only the boundary whose component does not resolve", :aggregate_failures do
    rows = run(boundary(component("Missing")), boundary(component("Good")), boundary("<p>third</p>"))
    expect(rows[0]).to match(/\A\h+:E\{/)
    expect(rows[1]).not_to include(":E{")
    expect(rows[1]).to include("/Good.js")
    expect(rows[2]).to include('"children":"third"')
  end

  # Review R1 — the content's own timeout (a slow API) is the content's error,
  # with its class and message, not the Suspense timeout.
  it "tells the content's own Timeout::Error from suspense_timeout", :aggregate_failures do
    rows = run(boundary(->(*) { raise Net::ReadTimeout, "the API" }))
    expect(rows[0]).to include("ruact:suspense-error")
    expect(rows[0]).not_to include("ruact:suspense-timeout")
  end

  it "ends a block that runs past suspense_timeout with the timeout row" do
    Ruact.configure { |c| c.suspense_timeout = 0.05 }
    rows = run(boundary(lambda { |*|
      sleep 1
      "<p>never</p>"
    }))
    expect(rows[0]).to include("ruact:suspense-timeout")
  end
end
