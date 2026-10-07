# frozen_string_literal: true

require "spec_helper"

# Story 18-1 — React's Flight client decodes what the Ruby side writes. The JS
# conformance suite (vendor/javascript/vite-plugin-ruact/flight-conformance.test.mjs)
# reads these payloads with the vendored client, production and development
# builds. This spec writes them and guards them against drift. Regenerate with
# RUACT_WRITE_FIXTURES=1.
module ConformanceFixtures
  DIR = File.expand_path("../../fixtures/flight", __dir__)

  MANIFEST = {
    "LikeButton" => { "id" => "/LikeButton.jsx", "name" => "LikeButton", "chunks" => ["/LikeButton.jsx"] },
    "Card" => { "id" => "/Card.jsx", "name" => "Card", "chunks" => ["/Card.jsx"] }
  }.freeze

  # Sibling children, an ERB loop of client components (ERB has no `key`), a
  # one-element data array, and a Suspense boundary.
  TREE = <<~ERB
    <main>
      <h1>Posts</h1>
      <% @likes.each do |n| %><article><LikeButton likes={n} tags={["only"]} /></article><% end %>
      <Suspense fallback="loading"><p>late</p></Suspense>
      <p>after</p>
    </main>
  ERB

  # Story 18-2 — a client component with children: server HTML, a loop of
  # client components, and the same component nested inside itself.
  CHILDREN = <<~ERB
    <Card title={@title}>
      <p>from ERB</p>
      <% @likes.each do |n| %><LikeButton likes={n} tags={["only"]} /><% end %>
      <Card title="inner">nested</Card>
    </Card>
  ERB

  def self.render_tree(development:, erb: TREE)
    pipeline = Ruact::RenderPipeline.new(Ruact::ClientManifest.from_hash(MANIFEST), development: development)
    ctx = Object.new
    ctx.instance_variable_set(:@likes, [1, 2, 3])
    ctx.instance_variable_set(:@title, "Server title")
    pipeline.render({ erb: erb, binding: ctx.instance_eval { binding } }, mode: :string)
  end

  # A Suspense child that ran past `suspense_timeout`: its row is an error.
  def self.render_timeout
    suspense = Ruact::Flight::SuspenseElement.new(
      fallback: Ruact::Flight::ReactElement.new(type: "span", props: { "children" => "loading" }),
      children: Ruact::Flight::ReactElement.new(type: "p", props: { "children" => "late" }),
      delay: 10.0
    )
    previous = Ruact.config.suspense_timeout
    Ruact.configure { |c| c.suspense_timeout = 1.0 }
    Ruact::Flight::Renderer.each(suspense, Ruact::ClientManifest.from_hash({}), streaming: true).to_a.join
  ensure
    Ruact.configure { |c| c.suspense_timeout = previous }
  end

  FILES = {
    "conformance_tree.txt" => -> { render_tree(development: false) },
    "conformance_tree_dev.txt" => -> { render_tree(development: true) },
    "conformance_suspense_timeout.txt" => -> { render_timeout },
    "conformance_children.txt" => -> { render_tree(development: false, erb: CHILDREN) },
    "conformance_children_dev.txt" => -> { render_tree(development: true, erb: CHILDREN) }
  }.freeze
end

RSpec.describe "Flight conformance fixtures" do
  ConformanceFixtures::FILES.each do |file, render|
    it "#{file} matches what the serializer emits today" do
      path = File.join(ConformanceFixtures::DIR, file)
      wire = render.call
      File.binwrite(path, wire) if ENV["RUACT_WRITE_FIXTURES"]
      expect(File.binread(path)).to eq(wire.b),
                                    "#{file} drifted from the serializer. Regenerate: " \
                                    "RUACT_WRITE_FIXTURES=1 bundle exec rspec #{__FILE__}"
    end
  end

  it "development rows carry React's validated flag; production rows do not", :aggregate_failures do
    elements = lambda do |wire|
      rows = Ruact::Testing::FlightWireParser.parse(wire).select { |row| row[:class] == :model }
      rows.flat_map { |row| collect_elements(row[:payload]) }
    end
    expect(elements.call(ConformanceFixtures.render_tree(development: false)).map(&:length).uniq).to eq([4])
    expect(elements.call(ConformanceFixtures.render_tree(development: true)).map { |e| e[4..] }.uniq)
      .to eq([[nil, nil, 1]])
  end

  it "emits one Suspense symbol row and one boundary import per response" do
    wire = ConformanceFixtures.render_tree(development: false)
    expect(wire.scan('"$Sreact.suspense"').length).to eq(1)
    expect(wire.scan('I["ruact:boundary",[],"SuspenseBoundary"]').length).to eq(1)
  end

  it "writes the timeout error as the object React's client reads" do
    error = Ruact::Testing::FlightWireParser.parse(ConformanceFixtures.render_timeout).find { |r| r[:class] == :error }
    expect(error[:payload]).to eq("digest" => "ruact:suspense-timeout", "name" => "Error",
                                  "message" => "Suspense timeout exceeded",
                                  "stack" => [], "env" => "Server")
  end

  def collect_elements(node)
    case node
    when Array
      own = node[0] == "$" && node[1].is_a?(String) ? [node] : []
      own + node.flat_map { |child| collect_elements(child) }
    when Hash then node.values.flat_map { |child| collect_elements(child) }
    else []
    end
  end
end
