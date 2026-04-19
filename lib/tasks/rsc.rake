# frozen_string_literal: true

namespace :rsc do
  desc "Check rails_rsc installation and configuration (FR27)"
  task doctor: :environment do
    require "rails_rsc/doctor"
    exit 1 unless RailsRsc::Doctor.run
  end
end
