# frozen_string_literal: true

namespace :rsc do
  desc "Check ruact installation and configuration (FR27)"
  task doctor: :environment do
    require "ruact/doctor"
    exit 1 unless Ruact::Doctor.run
  end
end
