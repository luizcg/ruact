# frozen_string_literal: true

module Ruact
  module Spec
    # Shared vocabulary for the specs that guard this repository's public
    # markdown — `spec/contributing_spec.rb`, `spec/releasing_spec.rb`.
    #
    # It lives here because the alternative is a second copy of a
    # forbidden-word list, and two lists that are supposed to say the same
    # thing and are edited in different files is the same drift bug the
    # documents themselves have. One list, two readers.
    #
    # Each gate still states its own promises in its own examples. Nothing
    # here asserts anything.
    module MarkdownGate
      # Everything that exists only on the private side of this project. A
      # public document naming any of these is either leaking structure or
      # sending its reader somewhere they cannot go — both are the same bug
      # from the reader's chair.
      PRIVATE_SIDE = [
        /ruact-dev/i,
        /_bmad-output/i,
        %r{playgrounds/}i,
        %r{website/}i,
        %r{docs/examples/}i,
        /bmad/i,
        /sprint-status/i
      ].freeze

      # The false claim these documents are one edit away from making. `main`
      # has no branch protection and no rulesets, so nothing is enforced at
      # merge time — the honest phrasing is "runs on every pull request".
      # These are the shapes that would break that. `required` on its own is
      # deliberately NOT among them: the word has an ordinary sense — a tool a
      # step needs — and banning it would cost the documents more than it
      # buys. What is banned is the SHAPE that asserts a merge gate.
      # (Describing the shape rather than quoting an offending sentence leaves
      # nothing to rot: a quoted sentence goes stale and the comment ends up
      # blessing a claim the document no longer makes.)
      ENFORCEMENT_CLAIMS = [
        /required[- ](status )?check/i,
        /must pass (before|to merge|for)/i,
        /cannot be merged/i,
        /blocked from merging/i,
        /branch protection/i
      ].freeze

      # `[text](target)` and `![alt](target)`, inline-title form allowed. Same
      # recogniser `spec/readme_spec.rb` uses, for the same reason.
      def self.link_targets(markdown)
        markdown.scan(/\[[^\]]*\]\(([^)\s]+)(?:\s+"[^"]*")?\)/).flatten
      end

      # Absolute URLs, anchors and mailto: links are somebody else's problem;
      # on-disk targets are ours.
      def self.relative(targets)
        targets.reject { |target| target.start_with?("http://", "https://", "#", "mailto:") }
      end

      # ```jsx, ```erb, ```ruby and ```markdown blocks are illustrations, not
      # commands, and are deliberately out of scope.
      def self.bash_blocks(markdown)
        markdown.scan(/^```bash[ \t]*\n(.*?)^```/m).flatten
      end
    end
  end
end
