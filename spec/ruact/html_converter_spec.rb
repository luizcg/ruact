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
      it "replaces RSC comment placeholder with the registered ReactElement" do
        ref      = Flight::ClientReference.new(module_id: "./LikeButton", export_name: "LikeButton")
        registry = [{ token: "__RSC_0__", name: "LikeButton", ref: ref, props: { "postId" => 1 } }]
        result   = convert.call("<!-- __RSC_0__ -->", registry)

        expect(result).to be_a(Flight::ReactElement)
        expect(result.type).to eq(ref)
        expect(result.props).to eq({ "postId" => 1 })
      end

      it "wraps a client component inside a parent DOM element" do
        ref      = Flight::ClientReference.new(module_id: "./Button", export_name: "Button")
        registry = [{ token: "__RSC_0__", name: "Button", ref: ref, props: {} }]
        result   = convert.call('<div class="wrapper"><!-- __RSC_0__ --></div>', registry)

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
  end
end
