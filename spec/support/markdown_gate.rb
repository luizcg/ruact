# frozen_string_literal: true

module Ruact
  module Spec
    # Shared vocabulary for the specs that guard this repository's public
    # markdown.
    #
    # It lives here because the alternative is a copy per gate, and lists that
    # are supposed to say the same thing but are edited in different files are
    # the same drift bug the documents themselves have.
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
      # merge time — the honest phrasing names what the workflow does (it runs)
      # rather than what it decides (nothing).
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

      # `[text](target)` and `![alt](target)`, inline-title form allowed.
      def self.link_targets(markdown)
        markdown.scan(/\[[^\]]*\]\(([^)\s]+)(?:\s+"[^"]*")?\)/).flatten
      end

      # Absolute URLs, anchors and mailto: links are somebody else's problem;
      # on-disk targets are ours.
      def self.relative(targets)
        targets.reject { |target| target.start_with?("http://", "https://", "#", "mailto:") }
      end

      # One definition of what a fence is, because two recognisers that disagree
      # about it disagree about what is code and what is prose — and a gate
      # reading one while its neighbour reads the other is how a block ends up
      # pinned by nobody. Follows CommonMark on the three things a regex gets
      # wrong: the closing run must be at least as long as the opening one (so
      # a ````four-backtick block can contain a ```three-backtick one), tildes
      # fence too, and an unterminated fence runs to the end of the document
      # rather than pairing with the next opening fence it happens to meet.
      #
      # Returns one entry per fence: its info string, the body lines with the
      # opening fence's indent removed, and whether it was ever closed.
      def self.fenced_regions(markdown)
        lines = markdown.lines
        regions = []
        open = nil

        lines.each_with_index do |line, index|
          match = line.match(/\A( {0,3})(`{3,}|~{3,})(.*)\Z/)

          if open.nil?
            next unless match

            open = { indent: match[1], marker: match[2], info: match[3].strip, first: index }
          elsif closing?(match, open)
            regions << open.merge(last: index, closed: true)
            open = nil
          end
        end
        regions << open.merge(last: lines.length, closed: false) if open

        regions.each { |region| region[:body] = body_of(lines, region) }
      end

      # A closing fence is the same character, at least as long, and carries no
      # info string of its own.
      def self.closing?(match, open)
        return false unless match

        match[2][0] == open[:marker][0] && match[2].length >= open[:marker].length && match[3].strip.empty?
      end
      private_class_method :closing?

      def self.body_of(lines, region)
        lines[(region[:first] + 1)...region[:last]].to_a.map { |line| line.sub(/\A#{region[:indent]}/, "") }.join
      end
      private_class_method :body_of

      # The document with every fenced block removed. What is left is prose —
      # the part where a heading is a heading and a link is a link.
      def self.prose(markdown)
        fenced = fenced_regions(markdown).flat_map { |region| (region[:first]..region[:last]).to_a }
        kept = markdown.lines.each_with_index.reject { |_, index| fenced.include?(index) }

        kept.map(&:first).join
      end

      def self.fences_left_open(markdown)
        fenced_regions(markdown).reject { |region| region[:closed] }
      end

      # Blocks whose info string starts with one of `languages`.
      def self.code_blocks(markdown, *languages)
        fenced_regions(markdown).filter_map do |region|
          region[:body] if languages.include?(region[:info][/\A\S+/])
        end
      end

      # Every shell block a reader could copy, however the fence is spelled and
      # wherever it sits. ```jsx, ```erb and ```ruby blocks are illustrations,
      # not commands, and are deliberately out of scope.
      def self.bash_blocks(markdown)
        code_blocks(markdown, "bash", "sh", "shell", "console")
      end

      def self.markdown_blocks(markdown)
        code_blocks(markdown, "markdown", "md")
      end
    end
  end
end
