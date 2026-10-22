# Neutralise reviewer-authored prose before a renderer prints it as markdown.
#
# Reviewers read a diff the PR author controls, so every prose field a reviewer
# writes is untrusted at render time: a prompt-injected reviewer can close the
# comment's <details> early, hide the rest of it in an unclosed <!--, print a
# forged verdict heading or marker, ping people from the bot account, or embed
# a tracking image. This library is the one place those are defused. Extend it
# here rather than escaping at a call site.
#
# Library, not program: callers load it with
#   jq -L "$RC_JQ_DIR" 'include "md-neutralise"; ... | rc_md_neutralise'
# so it runs inside a caller's existing jq call rather than adding one.
#
# Formatting that can neither break layout nor reach people (bold, italics,
# inline code, plain links, list markers) survives. Every rule below was checked
# against GitHub's POST /markdown (gfm) and GitLab's POST /api/v4/markdown
# before it was written; docs/dev/pipeline.md says how to re-probe.
#
# HTML safety does not depend on finding code spans the way the renderer does.
# Outside the <code> elements this emits, every "<", "&" and unescaped backtick
# becomes an entity, so nothing there can open HTML, decode an entity or pair
# into a span. Inside them, every ASCII punctuation character is backslash-
# escaped or an entity, so nothing there can either. A span detected where the
# renderer sees none therefore reads oddly, but is never live.
#
# The output is not idempotent ("&amp;" becomes "&amp;amp;"). Each field is
# neutralised at exactly one call site; never neutralise a neutralised string.
#
# Everything here is linear in the field's length. jq 1.7's gsub, scan and
# match(...; "g") recompute each match's offset from the start of the string,
# which is quadratic in the match count, so this uses only literal split, add,
# explode/implode, and regexes anchored to one line or one token.

# Join an array of strings with $sep. jq's join is quadratic in the element
# count; add is not.
def _rc_md_join($sep):
  if length == 0 then "" else [.[0], (.[1:][] | $sep, .)] | add end;

# Replace every occurrence of the literal string $from with $to.
def _rc_md_replace($from; $to):
  split($from) | _rc_md_join($to);

# Every line ending a renderer honours becomes "\n": CommonMark ends a line at
# CRLF and at a lone CR, and the Unicode separators are folded too, so the
# per-line block rule below sees the lines the renderer sees.
def _rc_md_lf:
  _rc_md_replace("\r\n"; "\n") | _rc_md_replace("\r"; "\n")
  | _rc_md_replace("\u0085"; "\n") | _rc_md_replace("\u2028"; "\n")
  | _rc_md_replace("\u2029"; "\n");

# Codepoint classes: a word character ([A-Za-z0-9_]), and the characters a
# mention may continue with (word, ".", "/", "-", "@").
def _rc_md_word:
  (. >= 48 and . <= 57) or (. >= 65 and . <= 90) or (. >= 97 and . <= 122) or . == 95;
def _rc_md_name:
  _rc_md_word or . == 45 or . == 46 or . == 47 or . == 64;

# A code span's content (or a mention) as a <code> element whose content can
# only be text. Inline HTML does not stop markdown parsing inside it, so every
# ASCII punctuation character is backslash-escaped, and "&", "<" and ">" become
# entities. Line endings become spaces and one padding space is stripped from
# each end, as CommonMark does for a span.
def _rc_md_code_html:
  ("&amp;" | explode) as $amp | ("&lt;" | explode) as $lt | ("&gt;" | explode) as $gt
  | _rc_md_replace("\n"; " ")
  | if startswith(" ") and endswith(" ") and test("[^ ]") then .[1:-1] else . end
  | "<code>"
    + ([explode[]
        | if . == 38 then $amp[]
          elif . == 60 then $lt[]
          elif . == 62 then $gt[]
          elif (. >= 33 and . <= 47) or (. >= 58 and . <= 64)
            or (. >= 91 and . <= 96) or (. >= 123 and . <= 126) then 92, .
          else . end]
       | implode)
    + "</code>";

# Wrap each mention in <code>. A mention is "@" not preceded by a word
# character (neither forge links email@example.com or x@user), then a word
# character or ".", then the rest of a user, group or team path; "@" continues it, so
# "@a@b" is wrapped whole. Trailing ".", "/" and "@" are left outside, so a
# sentence's full stop is not swallowed; a lone "@." is no mention. A backslash before the "@" is spaced
# off: it would otherwise escape the "<" of the tag and print it as text.
# A backslash does not stop GitHub linking "\@user", and an entity does not stop
# either forge; <code> stops both.
def _rc_md_mentions:
  explode as $c
  | [foreach range(0; ($c | length) + 1) as $i ({s: null, out: null};
      .out = null
      | $c[$i] as $ch
      | if .s != null then
          if $ch != null and ($ch | _rc_md_name) then .
          else .out = [.s, $i] | .s = null end
        elif $ch == 64 and ($i == 0 or ($c[$i - 1] | _rc_md_word | not))
          and (($c[$i + 1] // 0) | _rc_md_word or . == 46) then .s = $i
        else . end;
      .out | select(. != null)
      | until(.[1] - .[0] < 2 or ($c[.[1] - 1] | . == 46 or . == 47 or . == 64 | not); .[1] -= 1)
      | select(.[1] - .[0] > 1))] as $runs
  | [foreach ($runs[], null) as $r ({at: 0};
      .from = .at | .at = (if $r == null then null else $r[1] end);
      if $r == null then $c[.from:] | implode
      else ($c[.from:$r[0]] | implode),
        (if $r[0] > 0 and $c[$r[0] - 1] == 92 then " " else "" end),
        ($c[$r[0]:$r[1]] | implode | _rc_md_code_html)
      end)]
  | add;

# Text outside every code span (it holds no backtick).
#   1. "&" -> "&amp;" and "<" -> "&lt;": no raw HTML, no <details>/</details>,
#      no <!-- comment, no forged marker or part-links token, and no entity
#      (&#64; and &commat; still notify on both forges).
#   2. A mention -> <code>, above.
#   3. "![" -> "!\[": the image renders as text, so nothing is fetched.
def _rc_md_text:
  _rc_md_replace("&"; "&amp;")
  | _rc_md_replace("<"; "&lt;")
  | _rc_md_replace("!["; "!\\[")
  | if contains("@") then _rc_md_mentions else . end;

# The number of backslashes a string ends with.
def _rc_md_trailing_backslashes:
  if endswith("\\") | not then 0
  else explode | length - ((map(. != 92) | rindex(true)) // -1) - 1 end;

# Split a string into text and backtick runs: a run is a number (its length),
# text a string, alternating.
def _rc_md_tokens:
  split("`") as $p
  | [($p[0] // "" | select(. != "")),
     foreach ($p[1:][], null) as $q ({run: 0, out: []};
       if $q == null then .out = (if .run > 0 then [.run] else [] end)
       elif $q == "" then .run += 1 | .out = []
       else .out = [.run + 1, $q] | .run = 0 end;
       .out[])];

# Find code spans the way CommonMark pairs backticks: a run of N opens a span
# that the next run of exactly N closes (a backslash escapes nothing inside a
# span), a backtick escaped by an odd number of backslashes opens nothing, and
# an unclosed run is literal. Emits, in order, {text} for text outside spans,
# {lit} for backticks outside spans, and {lit, code} for a span (lit being the
# escaped backtick before an escaped opener, if any).
#
# Outside backticks become "&#96;" so they cannot pair in the renderer with a
# backtick this did not pair them with; an escaped one stays "\`", which opens
# nothing either.
#
# $next[i] holds, for run i, the index of the next run of the same length and
# of one shorter (the length an escaped opener has), found in one reverse pass.
def _rc_md_segments:
  _rc_md_tokens as $t
  | ($t | length) as $n
  | ([foreach range($n - 1; -1; -1) as $i ({last: {}, cur: null};
       if ($t[$i] | type) == "number" then
         .cur = [.last["\($t[$i])"], .last["\($t[$i] - 1)"]]
         | .last["\($t[$i])"] = $i
       else .cur = null end;
       .cur)] | reverse) as $next
  | foreach range($n) as $i ({to: -1, out: null};
      if $i <= .to then .out = null
      elif ($t[$i] | type) == "string" then .out = {text: $t[$i]}
      else
        (if $i > 0 and ($t[$i - 1] | _rc_md_trailing_backslashes) % 2 == 1 then 1 else 0 end) as $esc
        | ($t[$i] - $esc) as $len
        | (if $esc == 1 then "`" else "" end) as $lit
        | $next[$i][$esc] as $j
        | if $len == 0 then .out = {lit: $lit}
          elif $j == null then .out = {lit: ($lit + "&#96;" * $len)}
          else
            .out = {lit: $lit,
                    code: ($t[$i + 1:$j] | map(if type == "number" then "`" * . else . end) | add)}
            | .to = $j
          end
      end;
      .out | select(. != null));

# The block rule, per line: backslash-escape the first character of a block
# construct at the start of a line, after any indentation and any list markers
# ("-", "+", "*", "1.", "1)", repeated), so "- ## H" is escaped as well as
# "## H". Constructs: a heading "#", a blockquote ">", a tilde fence of three or
# more whatever follows it, a footnote or link reference definition "[x]:" (or
# a "[" with no unescaped "]" on its line, whose label may close on the next:
# "\]" does not close a label), a GitLab quick action "/", and a line made only
# of thematic-break, setext-underline or table-delimiter characters.
# Quick actions: GitLab matches ^\/(?<cmd>...) against the source of each
# top-level paragraph whose text starts with "/" (gitlab-org/gitlab
# lib/gitlab/quick_actions/extractor.rb:185-191) and runs /approve, /close,
# /label, /assign ... with the posting token's rights. Up to three leading spaces
# still make a paragraph; "\/" cannot match and renders "/". Escaping after
# indentation beyond that or after list markers is harmless, so it is uniform.
# A one-character "=" or "-" under text is a setext heading on both forges, so
# length does not matter. A whole such line is checked before markers are
# skipped: "- " under text is a setext underline, not an empty list item.
# Backtick fences need no rule: no unescaped backtick is left outside a span.
# The marker prefix is atomic so a long run of markers cannot backtrack.
def _rc_md_break: "(?=[-=*_:| \\t]*[-=*_])[-=*_:|][-=*_:| \\t]*\\z";
def _rc_md_block_line:
  (if test("\\A[ \\t]*" + _rc_md_break) then match("\\A[ \\t]*").length
   else first(match("\\A(?>[ \\t]*(?:(?:[-+*]|[0-9]{1,9}[.)])[ \\t]+)*)(?=#|>|/|~~~|\\[(?:[^\\]\\\\]|\\\\.)*(?:\\]:|\\\\?\\z)|"
       + _rc_md_break + ")") | .length) // null
   end) as $k
  | if $k == null then . else .[:$k] + "\\" + .[$k:] end;

# House style: em and en dashes (U+2014, U+2013) print as "-". Mapped by
# codepoint to keep this file ASCII. It must run before neutralising, never
# after: a line of dashes that the neutraliser passed would otherwise become a
# setext underline, and "- ## x" a list item holding a live heading.
def _rc_md_dashes:
  explode | map(if . == 8212 or . == 8211 then 45 else . end) | implode;

# Neutralise one prose field. Every caller wants the dash pass, so it lives
# here where the order cannot be got wrong; evidence is fenced, never passed.
def rc_md_neutralise:
  _rc_md_dashes
  | _rc_md_lf
  | [_rc_md_segments
     | if has("text") then .text | _rc_md_text
       elif has("code") then .lit + (.code | _rc_md_code_html)
       else .lit end]
  | add // ""
  | split("\n") | map(_rc_md_block_line) | _rc_md_join("\n");

# A title is one line. It is printed inline in a list item's first line, where
# a newline would start a new top-level line, so every line ending (and the
# vertical tab and form feed) becomes one space before neutralising. The
# renderer prints it between "**" markers, so a trailing unescaped backslash is
# doubled: it would otherwise escape the closing "*" and print it.
def rc_md_title:
  _rc_md_lf | _rc_md_replace("\u000b"; "\n") | _rc_md_replace("\u000c"; "\n")
  | [split("\n")[] | select(. != "")] | _rc_md_join(" ")
  | rc_md_neutralise
  | if _rc_md_trailing_backslashes % 2 == 1 then . + "\\" else . end;

# A value the renderer prints as code but did not choose, such as a finding's
# file path (the change author names the file), as the same inert <code>
# element a code span becomes. Line endings are folded first so a lone CR ends
# up a space like "\n" does. Dashes are kept: the value is verbatim, not prose.
def rc_md_code:
  _rc_md_lf | _rc_md_code_html;
