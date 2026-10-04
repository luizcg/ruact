# frozen_string_literal: true

# Story 18-0: ruact's payloads for the six spike cases, written to ARGV[0].
require "ruact"
out = ARGV[0]
manifest = Ruact::ClientManifest.from_hash(
  "LikeButton" => { "id" => "/LikeButton.jsx", "name" => "LikeButton", "chunks" => ["/LikeButton.jsx"] }
)
pipeline = Ruact::RenderPipeline.new(manifest)
erb = lambda do |src|
  ctx = Object.new
  pipeline.render({ erb: src, binding: ctx.instance_eval { binding } }, mode: :string)
end
data = ->(v) { Ruact::Flight::Renderer.render(v, manifest) }
cases = {
  "scalars" => data.call({ "s" => "hi", "dollar" => "$5 plan", "i" => 42, "f" => 3.14, "t" => true, "n" => nil,
                           "nan" => Float::NAN, "inf" => Float::INFINITY, "ninf" => -Float::INFINITY,
                           "und" => :undefined, "date" => Time.utc(2026, 9, 8, 12, 30, 45, 123_000),
                           "big" => (2**53) + 1 }),
  "longText" => data.call({ "body" => "é" * 600 }),
  "hostTree" => erb.call(%(<div><h1>Hello</h1><p class="x">World</p></div>)),
  "clientComponent" => erb.call(%(<LikeButton likes={12} />)),
  "nested" => erb.call(%(<ul><% [1, 2].each do |i| %><li><LikeButton likes={i} /></li><% end %></ul>)),
  "suspense" => erb.call(%(<Suspense fallback="loading"><p>late</p></Suspense>))
}
cases.each { |name, wire| File.write(File.join(out, "#{name}.txt"), wire) }
puts(cases.map { |n, w| "=== #{n}\n#{w}" })
