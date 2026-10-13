# frozen_string_literal: true

module Spike
  # The entry <script> for a document that stays open while rows arrive.
  #
  # A module script is deferred: it runs when the parser reaches the end of the
  # document, which here is after the last deferred row. `async` makes it run as
  # soon as it has loaded. In development the react-refresh preamble has to run
  # before any component module, so one async inline module installs it and
  # then imports the entry.
  module EntryTags
    ENTRY = "app/javascript/entry.js"

    def spike_entry_tags
      if Rails.env.development?
        dev = Ruact.config.vite_dev_server.chomp("/")
        <<~HTML.html_safe
          <script type="module" async>
            import RefreshRuntime from '#{dev}/@react-refresh';
            RefreshRuntime.injectIntoGlobalHook(window);
            window.$RefreshReg$ = () => {};
            window.$RefreshSig$ = () => (type) => type;
            window.__vite_plugin_react_preamble_installed__ = true;
            await import('#{dev}/@vite/client');
            await import('#{dev}/#{ENTRY}');
          </script>
        HTML
      else
        manifest = JSON.parse(Rails.root.join("public/assets/.vite/manifest.json").read)
        %(<script type="module" async src="/assets/#{manifest.fetch(ENTRY).fetch('file')}"></script>).html_safe
      end
    end
  end
end

ActiveSupport.on_load(:action_view) { include Spike::EntryTags }
