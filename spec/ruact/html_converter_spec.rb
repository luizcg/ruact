# frozen_string_literal: true

require "spec_helper"

module Ruact
  RSpec.describe HtmlConverter do
    subject(:convert) { ->(html, registry = []) { described_class.convert(html, registry) } }

    describe "text nodes" do
      it "returns a plain string for plain text" do
        expect(convert.call("hello")).to eq("hello")
      end
    end

    # Bugfix (Sprint Change Proposal 2026-06-16 §4.5): the ERB `delay` attribute
    # is carried as `data-ruact-delay` and must reach SuspenseElement#delay; an
    # absent, blank, or unparseable value falls back to the element's default.
    describe "Suspense element conversion (delay)" do
      let(:default_delay) do
        Ruact::Flight::SuspenseElement.new(fallback: nil, children: "x").delay
      end

      it "parses data-ruact-delay into SuspenseElement#delay as a Float" do
        html = %(<ruact-suspense data-ruact-fallback="loading" data-ruact-delay="2.5"><p>content</p></ruact-suspense>)
        result = convert.call(html)
        expect(result).to be_a(Ruact::Flight::SuspenseElement)
        expect(result.delay).to eq(2.5)
      end

      it "falls back to the default delay when the attribute is absent" do
        html = %(<ruact-suspense data-ruact-fallback="loading"><p>content</p></ruact-suspense>)
        result = convert.call(html)
        expect(result).to be_a(Ruact::Flight::SuspenseElement)
        expect(result.delay).to eq(default_delay)
      end

      it "falls back to the default delay when the attribute is unparseable" do
        html = %(<ruact-suspense data-ruact-fallback="loading" data-ruact-delay="soon"><p>content</p></ruact-suspense>)
        expect(convert.call(html).delay).to eq(default_delay)
      end

      it "falls back to the default delay when the attribute is blank" do
        html = %(<ruact-suspense data-ruact-fallback="loading" data-ruact-delay=""><p>content</p></ruact-suspense>)
        expect(convert.call(html).delay).to eq(default_delay)
      end

      it "treats delay=\"0\" as an explicit zero delay, not absent" do
        html = %(<ruact-suspense data-ruact-fallback="loading" data-ruact-delay="0"><p>content</p></ruact-suspense>)
        expect(convert.call(html).delay).to eq(0.0)
      end

      it "parses a delay value with surrounding whitespace" do
        html = %(<ruact-suspense data-ruact-fallback="loading" data-ruact-delay=" 2.5 "><p>content</p></ruact-suspense>)
        expect(convert.call(html).delay).to eq(2.5)
      end

      it "falls back to the default delay when the value overflows to a non-finite Float" do
        # Float("1e309") => Infinity (Float() does not raise on overflow); a
        # non-finite delay must not reach the renderer's sleep (RangeError).
        html = %(<ruact-suspense data-ruact-fallback="loading" data-ruact-delay="1e309"><p>content</p></ruact-suspense>)
        expect(convert.call(html).delay).to eq(default_delay)
      end
    end

    describe "single DOM element" do
      it "converts a div with class and text child" do
        result = convert.call('<div class="box">hi</div>')
        expect(result).to be_a(Flight::ReactElement)
        expect(result.type).to eq("div")
        expect(result.props["className"]).to eq("box")
        expect(result.props["children"]).to eq("hi")
      end

      it "converts `for` attribute to `htmlFor`" do
        result = convert.call('<label for="email">Email</label>')
        expect(result.props.keys).to include("htmlFor")
        expect(result.props["htmlFor"]).to eq("email")
      end

      it "extracts `data-react-key` into the element key and removes it from props" do
        result = convert.call('<article data-react-key="post-1">body</article>')
        expect(result.key).to eq("post-1")
        expect(result.props).not_to have_key("data-react-key")
      end
    end

    describe "nested elements" do
      it "produces a child ReactElement for a nested element" do
        result = convert.call("<div><span>hello</span></div>")
        expect(result.type).to eq("div")
        child = result.props["children"]
        expect(child).to be_a(Flight::ReactElement)
        expect(child.type).to eq("span")
      end

      it "produces an array of children for multiple child elements" do
        result = convert.call("<ul><li>a</li><li>b</li></ul>")
        children = result.props["children"]
        expect(children).to be_an(Array)
        expect(children.length).to eq(2)
        expect(children[0].type).to eq("li")
        expect(children[1].type).to eq("li")
      end
    end

    describe "fragment (multiple root elements)" do
      it "returns an array for multiple sibling root elements" do
        result = convert.call("<p>one</p><p>two</p>")
        expect(result).to be_an(Array)
        expect(result.length).to eq(2)
      end
    end

    describe "client component via registry" do
      it "replaces Ruact comment placeholder with the registered ReactElement" do
        ref      = Flight::ClientReference.new(module_id: "./LikeButton", export_name: "LikeButton")
        registry = [{ token: "__RUACT_0__", name: "LikeButton", ref: ref, props: { "postId" => 1 } }]
        result   = convert.call("<!-- __RUACT_0__ -->", registry)

        expect(result).to be_a(Flight::ReactElement)
        expect(result.type).to eq(ref)
        expect(result.props).to eq({ "postId" => 1 })
      end

      it "wraps a client component inside a parent DOM element" do
        ref      = Flight::ClientReference.new(module_id: "./Button", export_name: "Button")
        registry = [{ token: "__RUACT_0__", name: "Button", ref: ref, props: {} }]
        result   = convert.call('<div class="wrapper"><!-- __RUACT_0__ --></div>', registry)

        expect(result.type).to eq("div")
        child = result.props["children"]
        expect(child).to be_a(Flight::ReactElement)
        expect(child.type).to eq(ref)
      end
    end

    describe "form element value handling" do
      it "converts text input value to defaultValue (uncontrolled)" do
        result = convert.call('<input type="text" value="hello" />')
        expect(result.props).to have_key("defaultValue")
        expect(result.props["defaultValue"]).to eq("hello")
        expect(result.props).not_to have_key("value")
      end

      it "preserves value on submit inputs (controlled is correct for buttons)" do
        result = convert.call('<input type="submit" value="Save" />')
        expect(result.props).to have_key("value")
        expect(result.props["value"]).to eq("Save")
        expect(result.props).not_to have_key("defaultValue")
      end

      it "preserves value on reset inputs" do
        result = convert.call('<input type="reset" value="Clear" />')
        expect(result.props["value"]).to eq("Clear")
        expect(result.props).not_to have_key("defaultValue")
      end

      it "converts textarea value to defaultValue" do
        result = convert.call('<textarea value="content">content</textarea>')
        expect(result.props["defaultValue"]).to eq("content")
        expect(result.props).not_to have_key("value")
      end

      it "converts select value to defaultValue" do
        result = convert.call('<select value="b"><option value="a">A</option><option value="b">B</option></select>')
        expect(result.props["defaultValue"]).to eq("b")
        expect(result.props).not_to have_key("value")
      end

      it "converts checked attribute to defaultChecked" do
        result = convert.call('<input type="checkbox" checked="checked" />')
        expect(result.props).to have_key("defaultChecked")
        expect(result.props["defaultChecked"]).to eq("checked")
        expect(result.props).not_to have_key("checked")
      end
    end

    describe "style attribute" do
      it "converts a CSS string to a camelCase hash" do
        result = convert.call('<h1 style="font-size:28px;font-weight:700;margin-bottom:24px">Title</h1>')
        expect(result.props["style"]).to eq({
                                              "fontSize" => "28px",
                                              "fontWeight" => "700",
                                              "marginBottom" => "24px"
                                            })
      end

      it "handles multi-word property values without splitting" do
        result = convert.call('<div style="max-width:640px;margin:40px auto">x</div>')
        expect(result.props["style"]).to eq({
                                              "maxWidth" => "640px",
                                              "margin" => "40px auto"
                                            })
      end
    end

    describe "input validation (Story 7.4)" do
      describe "nil input" do
        it "raises Ruact::HtmlConverterError" do
          expect { described_class.convert(nil) }.to raise_error(Ruact::HtmlConverterError)
        end

        it "message contains 'received nil; expected a String of HTML'" do
          expect { described_class.convert(nil) }
            .to raise_error(Ruact::HtmlConverterError,
                            /HtmlConverter\.convert received nil; expected a String of HTML/)
        end

        it "message contains the 'Most likely cause' hint" do
          expect { described_class.convert(nil) }
            .to raise_error(Ruact::HtmlConverterError, /Most likely cause:/)
          expect { described_class.convert(nil) }
            .to raise_error(Ruact::HtmlConverterError, /missing yield, an empty respond_to branch/)
        end

        it "message contains the documentation pointer" do
          expect { described_class.convert(nil) }
            .to raise_error(Ruact::HtmlConverterError,
                            /See HtmlConverter\.convert documentation for the canonical contract\./)
        end

        it "message points at the spec's file:line, not html_converter.rb (Called from)" do
          expected_line = __LINE__ + 1
          expect { described_class.convert(nil) }
            .to raise_error(Ruact::HtmlConverterError,
                            /Called from: #{Regexp.escape(__FILE__)}:#{expected_line}/)
        end

        it "does not invoke Nokogiri::HTML::DocumentFragment.parse" do
          allow(Nokogiri::HTML::DocumentFragment).to receive(:parse).and_call_original
          expect { described_class.convert(nil) }.to raise_error(Ruact::HtmlConverterError)
          expect(Nokogiri::HTML::DocumentFragment).not_to have_received(:parse)
        end
      end

      describe "non-String inputs" do
        it "raises with 'got Integer' and 'Received: 42' for an Integer" do
          expect { described_class.convert(42) }
            .to raise_error(Ruact::HtmlConverterError,
                            /HtmlConverter\.convert expected a String of HTML; got Integer/)
          expect { described_class.convert(42) }
            .to raise_error(Ruact::HtmlConverterError, /Received: 42/)
        end

        it "raises with 'got Symbol' for a Symbol" do
          expect { described_class.convert(:symbol) }
            .to raise_error(Ruact::HtmlConverterError, /got Symbol/)
          expect { described_class.convert(:symbol) }
            .to raise_error(Ruact::HtmlConverterError, /Received: :symbol/)
        end

        it "raises with 'got Array' for an Array" do
          expect { described_class.convert(["array"]) }
            .to raise_error(Ruact::HtmlConverterError, /got Array/)
          expect { described_class.convert(["array"]) }
            .to raise_error(Ruact::HtmlConverterError, /Received: \["array"\]/)
        end

        it "raises with 'got Hash' for a Hash" do
          expect { described_class.convert({ hash: 1 }) }
            .to raise_error(Ruact::HtmlConverterError, /got Hash/)
          expect { described_class.convert({ hash: 1 }) }
            .to raise_error(Ruact::HtmlConverterError, /Received: \{.*hash.*1.*\}/)
        end

        it "raises with 'got Object' for a generic Object" do
          expect { described_class.convert(Object.new) }
            .to raise_error(Ruact::HtmlConverterError, /got Object/)
        end

        it "message points at the spec's file:line for non-nil non-String input" do
          expected_line = __LINE__ + 1
          expect { described_class.convert(42) }
            .to raise_error(Ruact::HtmlConverterError,
                            /Called from: #{Regexp.escape(__FILE__)}:#{expected_line}/)
        end

        it "truncates large input previews to ≤ 84 chars (80 + '...')" do
          large_value = (1..10_000).to_a
          message = nil
          begin
            described_class.convert(large_value)
          rescue Ruact::HtmlConverterError => e
            message = e.message
          end

          received_line = message.lines.find { |l| l.include?("Received:") }
          expect(received_line).not_to be_nil
          preview = received_line.sub(/^\s*Received:\s/, "").strip
          expect(preview.length).to be <= 84
          expect(preview).to end_with("...")
        end
      end

      describe "subclasses and edge cases" do
        it "accepts String subclasses (e.g. ActionView SafeBuffer-like)" do
          safe_buffer_class = Class.new(String)
          input = safe_buffer_class.new("<div>hi</div>")
          expect { described_class.convert(input) }.not_to raise_error

          result = described_class.convert(input)
          expect(result).to be_a(Ruact::Flight::ReactElement)
          expect(result.type).to eq("div")
        end

        it "accepts an empty string without raising" do
          expect { described_class.convert("") }.not_to raise_error
        end

        it "raises Ruact::HtmlConverterError (not NoMethodError) for BasicObject inputs" do
          basic = BasicObject.new
          expect { described_class.convert(basic) }
            .to raise_error(Ruact::HtmlConverterError, /HtmlConverter\.convert expected a String of HTML/)
        end

        it "produces a readable message even when value#inspect raises" do
          hostile = Class.new do
            def inspect
              raise "I refuse to introspect"
            end
          end.new

          expect { described_class.convert(hostile) }
            .to raise_error(Ruact::HtmlConverterError, /Received: <inspect raised>/)
        end

        it "produces a readable message even when value#class raises (BasicObject)" do
          basic = BasicObject.new
          expect { described_class.convert(basic) }
            .to raise_error(Ruact::HtmlConverterError) do |error|
              expect(error.message).to include("got ")
              expect(error.message).not_to match(/got\s*$/)
            end
        end
      end

      describe "backtrace shape" do
        it "frame 0 of the backtrace points outside the gem" do
          described_class.convert(nil)
        rescue Ruact::HtmlConverterError => e
          expect(e.backtrace.first).not_to include("/lib/ruact/html_converter.rb")
          expect(e.backtrace.first).to include(__FILE__)
        end

        it "frame 0 references the test file when called from a spec" do
          described_class.convert(42)
        rescue Ruact::HtmlConverterError => e
          expect(e.backtrace.first).to start_with(__FILE__)
        end
      end
    end

    # Detailed coverage of HtmlConverter input validation (nil + non-String inputs,
    # backtrace shape, BasicObject handling) lives in the "input validation (Story 7.4)"
    # block above (lines 147-300). This regression suite is intentionally minimal — two
    # smoke specs that name the suite for greppability via `:story_7_7` and the
    # "Story 7.7" describe substring; do NOT duplicate the 7.4 detailed coverage here.
    describe "edge cases (Story 7.7) — code-review regression suite", :story_7_7 do
      it "raises Ruact::HtmlConverterError for nil input (smoke; full coverage at :147-184)" do
        expect { described_class.convert(nil) }.to raise_error(Ruact::HtmlConverterError) do |error|
          expect(error.message).to include("received nil")
          expect(error.message).to include("expected a String of HTML")
        end
      end

      it "raises Ruact::HtmlConverterError for a non-String input (smoke; full coverage at :186-243)" do
        expect { described_class.convert(42) }.to raise_error(Ruact::HtmlConverterError) do |error|
          expect(error.message).to include("expected a String of HTML")
          expect(error.message).to include("got Integer")
          expect(error.message).to include("Received: 42")
        end
      end
    end
  end
end
