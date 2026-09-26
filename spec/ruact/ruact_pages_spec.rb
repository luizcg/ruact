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
      # No Rails app here: templates live nowhere unless a spec says so.
      def self.ruact_template_path(action) = Pathname("/nonexistent/#{controller_path}/#{action}.html.erb")
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

  # Review round 1 (17.0g) — a view Rails renders implicitly (no method) is
  # an action; declaring it is not a typo.
  it "accepts a declared action that has a template but no method" do
    klass = controller { ruact_pages only: %i[about] }
    allow(klass).to receive(:ruact_template_path).with("about").and_return(Pathname(__FILE__))

    expect(klass.ruact_page_action?(:about)).to be(true)
  end

  # Review round 1 (17.0g) — a base controller's declaration is checked
  # against the base: a template-only page lives in the BASE's view folder, not
  # in each subclass's.
  it "checks the declaration against the class that made it" do
    parent = controller { ruact_pages only: %i[about] }
    allow(parent).to receive(:ruact_template_path).with("about").and_return(Pathname(__FILE__))
    child = Class.new(parent) do
      def self.name = "DraftsController"
      def self.ruact_template_path(action) = Pathname("/nonexistent/drafts/#{action}.html.erb")
    end

    expect(child.ruact_page_action?(:about)).to be(true)
  end

  # An except: naming a missing action excludes nothing — nothing to catch.
  it "does not check the names in except:" do
    klass = controller { ruact_pages except: %i[shwo] }

    expect(klass.ruact_page_action?(:show)).to be(true)
  end

  # Review round 1 (17.0g) — a scaffolded controller includes the concern
  # itself; under `--app` its parent already has it. The second include is a
  # no-op, and Ruact::Server still sits in front of it (its redirect_to calls
  # the concern's through super).
  it "is a no-op to include again under a parent that has it, Server still first", :aggregate_failures do
    require "ruact/server"
    parent = Class.new(ActionController::Base) { include Ruact::Controller }
    scaffolded = Class.new(parent) do
      include Ruact::Controller
      include Ruact::Server
    end

    expect(scaffolded.ancestors.count(Ruact::Controller)).to eq(1)
    expect(scaffolded.ancestors.index(Ruact::Server)).to be < scaffolded.ancestors.index(Ruact::Controller)
  end

  # A typo must not quietly become "not a ruact page".
  it "fails loudly when a declared page is not an action", :aggregate_failures do
    klass = controller { ruact_pages only: %i[shwo] }

    expect { klass.ruact_page_action?(:show) }
      .to raise_error(Ruact::ConfigurationError, /PostsController declares ruact_pages for shwo/)
  end
end
