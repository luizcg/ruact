# frozen_string_literal: true

require "action_controller"
require "spec_helper"
require "ruact/controller"

# Story 17.0g (FR116, D2) — a ruact "page" is a whole controller or the actions
# it declares. The navigation boundary proves the effect end to end
# (navigation_boundary_boot_spec.rb); this pins the declaration itself.
RSpec.describe "Ruact::Controller.ruact_pages", :story_17_0g do
  def controller(&body)
    Class.new(ActionController::Base) do
      include Ruact::Controller

      def self.name = "PostsController"
      def index; end
      def show; end
      def preview; end

      class_eval(&body) if body
    end
  end

  it "makes every action a page when nothing is declared" do
    expect(%w[index show preview].map { |a| controller.ruact_page_action?(a) }).to all(be(true))
  end

  it "narrows to the declared actions with only:", :aggregate_failures do
    klass = controller { ruact_pages only: %i[show] }

    expect(klass.ruact_page_action?(:show)).to be(true)
    expect(klass.ruact_page_action?("index")).to be(false)
  end

  it "excludes the listed actions with except:", :aggregate_failures do
    klass = controller { ruact_pages except: :index }

    expect(klass.ruact_page_action?(:index)).to be(false)
    expect(klass.ruact_page_action?(:show)).to be(true)
  end

  # An action that renders another template (`ruact_render(template:)`) has no
  # template of its own; declaring it is what makes it a page.
  it "counts an action declared by name as a page without a template of its own" do
    klass = controller { ruact_pages only: %i[preview] }
    allow(klass).to receive(:ruact_template_path).and_return(Pathname("/nonexistent/preview.html.erb"))

    expect(klass.ruact_page?(:preview)).to be(true)
  end

  it "is inherited, and a subclass can redeclare", :aggregate_failures do
    parent = controller { ruact_pages only: %i[show] }
    child = Class.new(parent)
    redeclared = Class.new(parent) { ruact_pages only: %i[index] }

    expect(child.ruact_page_action?(:show)).to be(true)
    expect(redeclared.ruact_page_action?(:show)).to be(false)
    expect(parent.ruact_page_action?(:index)).to be(false)
  end

  it "takes exactly one of only: and except:" do
    expect { controller { ruact_pages only: :show, except: :index } }.to raise_error(ArgumentError, /exactly one/)
    expect { controller { ruact_pages } }.to raise_error(ArgumentError, /exactly one/)
  end

  # A typo must not quietly become "not a ruact page".
  it "fails loudly when a declared page is not an action", :aggregate_failures do
    klass = controller { ruact_pages only: %i[shwo] }

    expect { klass.ruact_page_action?(:show) }
      .to raise_error(Ruact::ConfigurationError, /PostsController declares ruact_pages for shwo/)
  end
end
