# frozen_string_literal: true

# Story 8.3 — `Ruact::ServerFunctions::StandaloneContext`: AC3 surface
# (exposes params/request/session/cookies/headers; render/redirect_to/head
# raise NoMethodError; current_user memoizes + falls back to env key +
# raises CurrentUserNotConfiguredError when neither path produces a value).

require "spec_helper"
require "action_controller"
require "action_dispatch"

module Ruact
  module ServerFunctions
    RSpec.describe StandaloneContext, :story_8_3 do
      let(:env) { {} }
      let(:request) do
        ActionDispatch::Request.new(env.merge(
                                      "REQUEST_METHOD" => "POST",
                                      "rack.input" => StringIO.new("")
                                    ))
      end
      let(:params) { ActionController::Parameters.new("title" => "Hello") }
      let(:context) { described_class.new(params: params, request: request) }

      describe "exposed surface (AC3)" do
        it "exposes params (the action-call args, as ActionController::Parameters)" do
          expect(context.params).to be_a(ActionController::Parameters)
          expect(context.params[:title]).to eq("Hello")
        end

        it "exposes the live request" do
          expect(context.request).to be(request)
        end

        it "exposes headers via request.headers" do
          expect(context.headers).to be(request.headers)
        end
      end

      describe "blocked surface — render / redirect_to / head (AC3)" do
        it "render raises NoMethodError with the documented hint" do
          expect { context.render(json: { ok: true }) }
            .to raise_error(NoMethodError, /does not expose `render`/)
        end

        it "redirect_to raises NoMethodError with the documented hint" do
          expect { context.redirect_to("/login") }
            .to raise_error(NoMethodError, /does not expose `redirect_to`/)
        end

        it "head raises NoMethodError with the documented hint" do
          expect { context.head(:no_content) }
            .to raise_error(NoMethodError, /does not expose `head`/)
        end
      end

      describe "current_user resolver path (AC3)" do
        around do |example|
          Ruact.instance_variable_set(:@config, nil)
          Ruact.instance_variable_set(:@configured_at_least_once, false)
          example.run
        ensure
          Ruact.instance_variable_set(:@config, nil)
          Ruact.instance_variable_set(:@configured_at_least_once, false)
        end

        before do
          # Silence the warn-on-reconfigure noise.
          allow(Rails).to receive(:logger).and_return(Logger.new(IO::NULL))
        end

        it "raises Ruact::CurrentUserNotConfiguredError when no resolver is configured AND no env key is set" do
          expect { context.current_user }.to raise_error(Ruact::CurrentUserNotConfiguredError) do |err|
            expect(err.message).to include("Ruact.current_user requires Ruact.config.current_user_resolver")
            expect(err.message).to include("Devise")
            expect(err.message).to include("hand-rolled session")
          end
        end

        it "returns the configured resolver's value, passing request.env to the lambda" do
          user = Struct.new(:id).new(42)
          Ruact.configure do |c|
            c.current_user_resolver = lambda { |env_arg|
              expect(env_arg).to be(request.env)
              user
            }
          end
          expect(context.current_user).to be(user)
        end

        it "memoizes current_user across multiple calls (resolver invoked once)" do
          call_count = 0
          Ruact.configure do |c|
            c.current_user_resolver = lambda { |_env|
              call_count += 1
              :user
            }
          end
          context.current_user
          context.current_user
          context.current_user
          expect(call_count).to eq(1)
        end

        it "prefers an upstream-set request.env['ruact.current_user'] over the resolver" do
          env["ruact.current_user"] = :upstream_user
          resolver_called = false
          Ruact.configure do |c|
            c.current_user_resolver = lambda { |_env|
              resolver_called = true
              :resolver_user
            }
          end
          expect(context.current_user).to eq(:upstream_user)
          expect(resolver_called).to be(false)
        end

        it "falls back to the resolver when the env key is absent (not just nil)" do
          # Pitfall: env.key? differs from env.fetch — a `nil` value should still
          # prefer the env path. Verify by setting nil explicitly.
          env["ruact.current_user"] = nil
          Ruact.configure do |c|
            c.current_user_resolver = ->(_env) { :resolver_user }
          end
          expect(context.current_user).to be_nil
        end
      end

      describe "__ruact_current_user_read? (Pitfall #4 dev warning flag)" do
        it "is false when the block never reads current_user" do
          expect(context.__ruact_current_user_read?).to be(false)
        end

        it "flips to true when the block reads current_user" do
          Ruact.configure { |c| c.current_user_resolver = ->(_env) { :u } }
          context.current_user
          expect(context.__ruact_current_user_read?).to be(true)
        end
      end
    end
  end
end
