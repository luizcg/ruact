# frozen_string_literal: true

module Ruact
  # Story 19-1 (ADR D1) — in development, a `load_async` that cannot run in
  # the background says so, once per process.
  #
  # `load_async` is how a page starts its queries early, so they finish while
  # the shell is sent. Without `config.active_record.async_query_executor` —
  # the default of a new Rails app — Active Record has no thread to run the
  # query in and loads it where `load_async` is called, waiting for it, with no
  # sign that it did. The note sits in `load_async` itself, not in every
  # `<Suspense>`: an app that never calls it has nothing to fix.
  #
  # The other cases where Rails loads synchronously with the executor set
  # (inside a transaction, a full queue) are in the guide, not here.
  module LoadAsyncNote
    MESSAGE = "[ruact] load_async ran its query where it was called and waited for it: " \
              "config.active_record.async_query_executor is not set, so Active Record has no thread to run " \
              "it in. Set `config.active_record.async_query_executor = :global_thread_pool` " \
              "(config/application.rb) so a page's queries start early and finish while its shell is sent. " \
              "(Said once.)"

    # Prepended to ActiveRecord::Relation in development by the Railtie.
    module Relation
      def load_async
        LoadAsyncNote.note(::ActiveRecord.async_query_executor)
        super
      end
    end

    # Logs {MESSAGE} the first time it is asked with no executor.
    #
    # @param executor [Symbol, nil] `ActiveRecord.async_query_executor`
    # @return [void]
    def self.note(executor)
      return unless executor.nil?
      return if @noted

      @noted = true
      Rails.logger&.warn(MESSAGE)
      nil
    end

    # Forgets that it logged (specs).
    #
    # @api private
    def self.reset!
      @noted = false
    end
  end
end
