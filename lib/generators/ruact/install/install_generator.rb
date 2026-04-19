# frozen_string_literal: true

require "rails/generators"
require "ruact"

module Ruact
  module Generators
    # Installs ruact into the current Rails application.
    #
    # Performs the following actions:
    # 1. Creates config/initializers/ruact.rb
    # 2. Injects `include Ruact::Controller` into ApplicationController
    # 3. Injects the React root div into app/views/layouts/application.html.erb
    # 4. Creates app/javascript/components/.keep
    # 5. Creates vite.config.js (or shows manual instructions if one exists)
    # 6. Creates app/javascript/application.jsx (or skips if one exists)
    #
    # Run: rails generate ruact:install
    class InstallGenerator < Rails::Generators::Base
      source_root File.expand_path("templates", __dir__)

      desc "Installs ruact into the current Rails application"

      def create_initializer
        template "initializer.rb.tt", "config/initializers/ruact.rb"
      end

      def inject_controller_concern
        controller_file = "app/controllers/application_controller.rb"
        return unless File.exist?(destination_root.join(controller_file))

        content = File.read(destination_root.join(controller_file))
        if content.include?("Ruact::Controller")
          say_status "skip", "Ruact::Controller already included in ApplicationController", :yellow
          return
        end

        inject_into_file controller_file,
                         "\n  include Ruact::Controller\n",
                         after: /class ApplicationController.*\n/
      end

      def inject_layout_shell
        layout_file = "app/views/layouts/application.html.erb"
        return unless File.exist?(destination_root.join(layout_file))

        content = File.read(destination_root.join(layout_file))
        if content.include?("ruact: root")
          say_status "skip", "Rails RSC root already present in layout", :yellow
          return
        end

        inject_into_file layout_file,
                         "\n    <%# ruact: root %>\n    <div id=\"root\"></div>\n",
                         before: "  </body>"
      end

      def create_components_directory
        empty_directory "app/javascript/components"
        create_file "app/javascript/components/.keep" unless
          File.exist?(destination_root.join("app/javascript/components/.keep"))
      end

      def create_vite_config
        vite_config_file = destination_root.join("vite.config.js")

        if vite_config_file.exist?
          say_status "notice", "vite.config.js already exists — add the plugin manually:", :yellow
          say "  1. At the top of vite.config.js, add:"
          say "       import ruact from '#{Ruact.vite_plugin_path}';"
          say "  2. In the plugins array, add: ruact()"
          say ""
          say "  Re-run `rails generate ruact:install --force` to overwrite vite.config.js."
        else
          template "vite.config.js.tt", "vite.config.js"
        end
      end

      def create_javascript_entry
        template "application.jsx.tt", "app/javascript/application.jsx"
      end

      def show_post_install_message
        say ""
        say "=" * 60
        say "  ruact installed successfully!"
        say "=" * 60
        say ""
        say "Next steps:"
        say "  1. Start the Vite dev server:  npm run dev"
        say "  2. Start Rails:                rails server"
        say "  3. Add <MyComponent /> to any ERB view"
        say ""
        say "Note: Re-run this generator after updating the ruact gem"
        say "to refresh the bundled Vite plugin path in vite.config.js."
        say ""
      end
    end
  end
end
