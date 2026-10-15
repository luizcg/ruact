# frozen_string_literal: true

# Under app/, as in an app: ItemsController (app/controllers) inherits it, and
# production eager-loads app/ before app.rb's own classes exist.
class ApplicationController < ActionController::Base
  include Ruact::Controller
end
