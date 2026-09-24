# frozen_string_literal: true

require "rails/generators"
require "ruact"

module Ruact
  module Generators
    # Copies the layout ruact pages render into (`layouts/ruact`, shipped with
    # the gem) into the app, so the app owns it.
    #
    # Nothing needs configuring afterwards: the gem's view path is APPENDED by
    # the Railtie, behind the app's, so `app/views/layouts/ruact.html.erb` wins
    # by view-path order the moment it exists. That is the point of the ejected
    # copy — add the app's JavaScript, fonts, meta tags or anything else
    # `config.layout_stylesheets` cannot express.
    #
    # The cost, said once here and again when the command runs: an ejected
    # layout no longer changes when the gem does.
    #
    # Run: rails generate ruact:layout
    class LayoutGenerator < Rails::Generators::Base
      source_root Ruact.views_path

      desc "Copies ruact's layout into app/views/layouts/ruact.html.erb so your app owns it"

      DESTINATION = "app/views/layouts/ruact.html.erb"

      # `copy_file` already refuses to overwrite silently: an existing file
      # prompts, or is skipped/overwritten under `--skip`/`--force`, which is
      # the Rails convention every other generator follows.
      def copy_layout
        copy_file "layouts/ruact.html.erb", DESTINATION
      end

      def explain
        say ""
        say "  #{DESTINATION} now renders every ruact page, in place of the one"
        say "  ruact ships. It will no longer change when you upgrade the gem —"
        say "  compare it with #{File.join(Ruact.views_path, 'layouts/ruact.html.erb')}"
        say "  after an upgrade. Keep `<%= ruact_head_assets %>` in <head>, and"
        say "  `<div id=\"root\"></div>` with `<%= ruact_js_assets %>` in <body>:"
        say "  `rails ruact:doctor` checks all three."
        say ""
      end
    end
  end
end
