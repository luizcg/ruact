# frozen_string_literal: true

module Spike
  # Story 19-0, decision D6 — ActionController::Live for some actions of a
  # controller and not for others, chosen before the action runs.
  #
  # Live does two things per request: its `process` runs the action in a thread
  # of its own, and its `make_response!` gives the action a response whose body
  # is a queue. Both are decided before any template is looked at, so "does this
  # page have a <Suspense>?" cannot be the question. "Is this action one that
  # may stream?" can: the route has already named the action.
  #
  # Here every action streams except `plain` (SPIKE_SELECTIVE=1). In the gem the
  # question would be "is this action a ruact page?".
  module SelectiveLive
    def self.included(base)
      base.include(ActionController::Live)
      base.extend(ClassMethods)
      base.prepend(Process)
    end

    module ClassMethods
      def spike_streams?(action)
        action.to_s != "plain"
      end

      def make_response!(request)
        return super if spike_streams?(request.path_parameters[:action])

        ActionDispatch::Response.new.tap { |response| response.request = request }
      end
    end

    module Process
      def process(name)
        return super if self.class.spike_streams?(name)

        live = method(:process)
        live = live.super_method until live.owner == ActionController::Live
        live.super_method.call(name)
      end
    end
  end
end
