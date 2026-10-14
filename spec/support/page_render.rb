# frozen_string_literal: true

require "action_view"

# Renders an ERB template the way a ruact page renders it in production: the
# preprocessor, an ActionView view with ruact's helpers (so `capture`, partial
# rendering and output escaping are Rails' own), a render context, and the
# pipeline that turns the HTML into Flight rows. No controller, no request.
#
#   PageRender.flight('<LikeButton postId={@id} />', manifest: manifest, assigns: { id: 1 })
#
# The specs that write the wire fixtures and the matcher specs go through
# here, so what they check is what a page sends.
module PageRender
  # @param erb [String] the template source, as a view file would hold it
  # @param manifest [Ruact::ClientManifest]
  # @param assigns [Hash] the view's instance variables, by name
  # @param mode [Symbol] :string (the whole payload) or :stream (an Enumerator of rows)
  def self.flight(erb, manifest:, assigns: {}, development: false, mode: :string)
    context = Ruact::RenderContext.new
    html = view(assigns, context).render(inline: Ruact::ErbPreprocessor.transform(erb, registry: manifest), type: :erb)
    Ruact::RenderPipeline.new(manifest, development: development)
                         .render({ html: html, render_context: context }, mode: mode)
  end

  def self.view(assigns, context)
    view_class = ActionView::Base.with_empty_template_cache
    view_class.include(Ruact::ViewHelper)
    view = view_class.new(ActionView::LookupContext.new([]), assigns.transform_keys(&:to_s), nil)
    # What Ruact::Controller hands the view: the context the helpers register in.
    view.instance_variable_set(:@ruact_render_context, context)
    view
  end
end
