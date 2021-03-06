require "regexp_parser"

# Format generated by Regexp::Parser is not convenient at all,
# let's translate it into something more useful
class SimpleRegexpParser
  def initialize(str, context)
    @tree = Regexp::Parser.parse(str)
    @context = context
    @group_number = 0
  end

  def new_group
    @group_number += 1
    "#{@context}-#{@group_number}"
  end

  def sequence(*parts)
    parts = parts.select{|x| x[0] != :empty}
    case parts.size
    when 0
      [:empty]
    when 1
      parts[0]
    else
      while parts.size > 1
        parts.unshift [:seq, parts.shift, parts.shift]
      end
      parts[0]
    end
  end

  def alternative(*parts)
    case parts.size
    when 0
      raise "Can't have empty alternative"
    when 1
      parts[0]
    else
      while parts.size > 1
        parts.unshift [:alt, parts.shift, parts.shift]
      end
      parts[0]
    end
  end

  # Saves us time to reuse ruby regexp engine for 1 character case
  def character_type(char_rx)
    char_rx = Regexp.new(char_rx)
    codes = (0..127).select{|c| c.chr =~ char_rx}
    # This is mostly here to make debugging easier
    if codes.size > 127-codes.size
      [:neg_set, (0..127).to_a - codes]
    else
      [:set, codes]
    end
  end

  def character_set(negated, members)
    if negated
      character_type "[^#{members.join}]"
    else
      character_type "[#{members.join}]"
    end
  end

  def literal(chars)
    sequence(*chars.map{|c| character_type(c)})
  end

  def star(part)
    [:star, part]
  end

  def backref(num)
    [:backref, "#{@context}-#{num}"]
  end

  def group(number, part)
    [:group, number, part]
  end

  def empty
    [:empty]
  end

  def repeat(part, min, max)
    if max == -1
      sequence(star(part), *([part]*min))
    else
      maybe_part = alternative([:empty], part)
      sequence(*([part]*min), *([maybe_part] * (max-min)))
    end
  end

  # Groups and qualifiers interact in weird ways, (a){3} is actually aa(a)
  # We need to do extensive rewriting to make it work
  def repeat_group(part, min, max)
    base = part[2]
    if max == -1
      if min == 0 # (a)* -> |a*(a)
        alternative(
          empty,
          sequence(repeat(base, min, max), part)
        )
      else # (a){2,} -> a{1,}(a)
        sequence(repeat(base, min-1, max), part)
      end
    elsif max == 0 # a{0} -> empty, not really a thing
      :empty
    else
      if min == 0
        # (a){2,3} -> |a{1,2}(a)
        alternative(
          empty,
          sequence(repeat(base, min, max-1), part)
        )
      else # (a){2,3} -> a{1,2}(a)
        sequence(repeat(base, min-1, max-1), part)
      end
    end
  end

  # Try to express regexps with minimum number of primitives:
  # * seq  - ab
  # * alt  - a|b
  # * star - a*
  # * set  - a [a-z] [^a-z]
  # * empty
  # * backref - \1
  # * group - (a)
  def parse(node=@tree)
    result = case node
    when Regexp::Expression::Group::Capture
      # Assumes it's going to be parsed in right order
      group(new_group, sequence(*node.expressions.map{|n| parse(n)}))
    when Regexp::Expression::Alternation
      alternative(*node.expressions.map{|n| parse(n)})
    when Regexp::Expression::Assertion::Lookahead
      [:anchor, :lookahead, sequence(*node.expressions.map{|n| parse(n)})]
    when Regexp::Expression::Assertion::NegativeLookahead
      [:anchor, :negative_lookahead, sequence(*node.expressions.map{|n| parse(n)})]
    when Regexp::Expression::Assertion::Lookbehind
      [:anchor, :lookbehind, sequence(*node.expressions.map{|n| parse(n)})]
    when Regexp::Expression::Assertion::NegativeLookbehind
      [:anchor, :negative_lookbehind, sequence(*node.expressions.map{|n| parse(n)})]
    when Regexp::Expression::Subexpression
      # It's annoyingly subtypes a lot
      raise unless node.class == Regexp::Expression::Subexpression or
                   node.class == Regexp::Expression::Group::Passive or
                   node.class == Regexp::Expression::Root or
                   node.class == Regexp::Expression::Alternative
      sequence(*node.expressions.map{|n| parse(n)})
    when Regexp::Expression::CharacterSet
      character_set(node.negative?, node.members)
    when Regexp::Expression::Literal
      literal(node.text.chars)
    when Regexp::Expression::CharacterType::Base
      character_type(node.text)
    when Regexp::Expression::EscapeSequence::Base
      character_type(node.text)
    when Regexp::Expression::Backreference::Number
      num = node.text[%r[\A\\(\d+)\z], 1] or raise "Parse error"
      backref(num.to_i)
    when Regexp::Expression::Anchor::BeginningOfString
      [:anchor, :bos]
    when Regexp::Expression::Anchor::EndOfString
      [:anchor, :eos]
    when Regexp::Expression::Anchor::BeginningOfLine
      [:anchor, :bol]
    when Regexp::Expression::Anchor::EndOfLine
      [:anchor, :eol]
    else
      raise "Unknown expression"
    end
    if node.quantified?
      min = node.quantifier.min
      max = node.quantifier.max
      result = if result[0] == :group
        repeat_group(result, min, max)
      else
        repeat(result, min, max)
      end
    end

    result
  end
end
