# frozen_string_literal: true

# Story 19-2 (AC11) — a form page with a <Suspense> that reads `ruact_errors`.
# Under app/, as an app's own controller: the router submits a form to a
# controller the app owns itself (Story 17.0f), and hands the rest to the browser.
# `create` streams; `create_in_place` renders the same page without streaming;
# `create_redirect` sends the errors through the flash, the Bucket 1 way.
class ItemsController < ApplicationController
  ruact_streaming only: %i[new create create_redirect]

  def new; end

  def create
    item = Item.new(name: params[:name])
    return redirect_to "/" if item.save

    ruact_errors(item)
    render :new, status: :unprocessable_entity
  end

  def create_in_place
    item = Item.new(name: params[:name])
    return redirect_to "/" if item.save

    ruact_errors(item)
    @form_action = "/items/in_place"
    render :new, status: :unprocessable_entity
  end

  def create_redirect
    item = Item.new(name: params[:name])
    return redirect_to "/" if item.save

    ruact_errors(item)
    redirect_to "/items/new"
  end
end
