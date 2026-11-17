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
# {lit} for backticks outside spans, and {lit, len, code} for a span (lit being
# the escaped backtick before an escaped opener, if any; len the length of its
# delimiter runs).
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
            .out = {lit: $lit, len: $len,
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

# Someone else's reply, before a model reads it (prepare-context.sh). A forge
# renders some content invisibly, and a model reads it all: an HTML comment, a
# tag the forge sanitises away, a link reference definition or link title, a
# script or style block, a zero-width, bidi or Unicode tag character can carry
# an instruction no person on the thread sees. An image or a data: URI carries
# no argument, only bulk. Each is removed, with a marker where content was;
# tags are dropped but their text stays.
#
# Models CommonMark, the grammar GitHub and GitLab both parse, not either
# forge's sanitiser allowlist. When the scrubber and the forge might disagree,
# scrub more: never keep what a forge might hide.
#
# Code: a span is recognised on one line only and never across "|" (a blank
# line or a table cell ends it, so it cannot pair backticks across them), and
# only when every backtick run in its paragraph pairs on its own line: that is
# where this matches CommonMark exactly, and one unpaired run (which CommonMark
# pairs with a run on a later line) leaves the paragraph with no code
# protection. A fence is kept verbatim, and is recognised only when it opens at
# column 0: an indented opener may sit in a list item the forge closes at the
# next column-0 line, so it is paragraph text. An HTML block is raw: no code in
# it, the browser's lenient tag rules apply, and unclosed markup hides the rest
# of the reply. NUL is the internal cut sentinel, so it is stripped from the
# input first.
#
# Residuals, accepted: text hidden by CSS (style="display:none") cannot be told
# from shown text without rendering, and stays, as does an element hidden by an
# attribute (hidden) or a collapsed <details> (visible on click); a link
# reference definition whose label spans lines stays.
def _rc_scrub_attr: "\\s+[A-Za-z_:][A-Za-z0-9_.:-]*(?:\\s*=\\s*(?:[^\\s\"'=<>`]+|'[^']*'|\"[^\"]*\"))?";
def _rc_scrub_hidden_names: "(?i:script|style|template|noscript|svg|math)";
def _rc_scrub_media: "(?i:img|picture|source|video|audio|iframe|object|embed)";

# Inline alternatives, leftmost-first, the way a CommonMark parser tokenises:
# an escape, a code span (one line, no "|", so neither a paragraph break nor a
# table cell can split it), an autolink, then raw HTML. $mode "code" has code
# spans plus a "lone" run of backticks that pairs on no line; "text" has no
# code (a paragraph with a lone run); "raw" is an HTML block, where backticks
# pair nothing and the browser's lenient tag rules hold.
def _rc_scrub_re($mode):
  (if $mode != "raw" then
     "(?<esc>\\\\[!-/:-@\\[-`{-~])"
     + (if $mode == "code" then "|(?<code>(?<!`)(?<bt>`+)(?!`)[^\\n|]*?(?<!`)\\k<bt>(?!`))|(?<lone>`+)" else "" end)
   else "(?<esc>(?!))" end)
  + "|(?<auto><[A-Za-z][A-Za-z0-9.+-]{1,31}:[^<>\\x00-\\x20]*>)"
  + "|(?<cmt><!---?>|<!--(?s:.*?)-->)"
  + "|(?<cdata><!\\[CDATA\\[(?s:.*?)\\]\\]>)"
  + "|(?<pi><\\?(?s:.*?)\\?>)"
  + "|(?<decl><![A-Za-z][^>]*>)"
  + "|(?<hid><(?<hn>" + _rc_scrub_hidden_names + ")(?:" + _rc_scrub_attr + ")*\\s*/?>(?s:.*?)</(?i:\\k<hn>)\\s*>)"
  + "|(?<cut><" + _rc_scrub_hidden_names + "(?:" + _rc_scrub_attr + ")*\\s*/?>"
  + (if $mode == "raw" then "|<!--" else "" end) + ")"
  + (if $mode != "raw" then
       "|(?<tag></?(?<tn>[A-Za-z][A-Za-z0-9-]*)(?:" + _rc_scrub_attr + ")*\\s*/?>)"
     else
       "|(?<tag></?(?<tn>[A-Za-z][A-Za-z0-9-]*)(?:[^>\"']|\"[^\"]*\"|'[^']*')*>)"
       + "|(?<ucut><[A-Za-z/!?])"
     end)
  + "|(?<img>!\\[(?<alt>[^\\]\\n]*)\\]\\([^)\\n]*\\))"
  + "|(?<ltitle>\\[(?<lt>[^\\]\\n]*)\\]\\(\\s*(?<lu><[^<>\\n]*>|[^)\\s]*)\\s+(?:\"(?:[^\"\\\\]|\\\\.)*\"|'(?:[^'\\\\]|\\\\.)*'|\\((?:[^()\\\\]|\\\\.)*\\))\\s*\\))"
  + "|(?<data>\\(data:[^)\\s]*\\))";

def _rc_scrub_inline($mode):
  gsub(_rc_scrub_re($mode);
    if .esc then .esc
    elif .code then .code
    elif .lone then .lone
    elif .auto then .auto
    elif .cmt then "[HTML comment removed]"
    elif .cdata or .pi or .decl or .hid then ""
    elif .cut or .ucut then "\u0000"
    elif .tag then (if .tn | test("^" + _rc_scrub_media + "$") then "[embedded content]" else "" end)
    elif .img then "[image: \(.alt)]"
    elif .ltitle then "[\(.lt)](\(.lu))"
    elif .data then "(data URI removed)"
    else "" end);

# Link reference definitions render as nothing. Removed at any line start in a
# paragraph (after container markers): a false match only removes more.
def _rc_scrub_defs:
  gsub("(?:\\A|(?<=\\n))(?:[ \\t]*(?:>|[-+*]|\\d{1,9}[.)]))*[ \\t]*\\[(?!\\^)(?:[^\\]\\\\\\n]|\\\\.){0,999}[^\\]\\s\\\\](?:[^\\]\\\\\\n]|\\\\.){0,999}\\]:[ \\t]*\\n?[ \\t]*(?:<[^<>\\n]*>|[^\\s<>]\\S*)(?:[ \\t]*\\n?[ \\t]*(?:\"(?:[^\"\\\\]|\\\\.)*\"|'(?:[^'\\\\]|\\\\.)*'|\\((?:[^()\\\\]|\\\\.)*\\)))?[ \\t]*(?:\\n|\\z)"; "");

# HTML block start (CommonMark types 1-7), after any indentation and container
# markers: detecting one where the forge would not only scrubs more. Returns
# the end-condition regex, "" for "ends at a blank line", or null.
def _rc_scrub_html_start($para_open):
  (sub("\\A(?:[ \\t]*(?:>|[-+*](?=[ \\t])|\\d{1,9}[.)](?=[ \\t])))*[ \\t]*"; "")) as $s
  | if $s | test("\\A<(?i:pre|script|style|textarea)(?:[ \\t>]|\\z)") then "(?i:</(?:pre|script|style|textarea)>)"
    elif $s | test("\\A<!--") then "-->"
    elif $s | test("\\A<\\?") then "\\?>"
    elif $s | test("\\A<![A-Za-z]") then ">"
    elif $s | test("\\A<!\\[CDATA\\[") then "\\]\\]>"
    elif $s | test("\\A</?(?i:address|article|aside|base|basefont|blockquote|body|caption|center|col|colgroup|dd|details|dialog|dir|div|dl|dt|fieldset|figcaption|figure|footer|form|frame|frameset|h[1-6]|head|header|hr|html|iframe|legend|li|link|main|menu|menuitem|nav|noframes|ol|optgroup|option|p|param|search|section|summary|table|tbody|td|tfoot|th|thead|title|tr|track|ul)(?:[ \\t>]|/>|\\z)") then ""
    elif ($para_open | not) and ($s | test("\\A</?[A-Za-z][A-Za-z0-9-]*(?:" + _rc_scrub_attr + ")*\\s*/?>[ \\t]*\\z")) then ""
    else null end;

# Split into blocks: {code} fence lines (kept verbatim), {text} paragraphs,
# {raw} HTML blocks, {blank} lines.
def _rc_scrub_blocks:
  def flush: if (.buf | length) > 0 then .out += [{(.kind): (.buf | join("\n"))}] | .buf = [] else . end;
  reduce (split("\n")[]) as $l ({out: [], mode: "none", buf: [], kind: "text", fc: null, fl: 0, hend: null};
    if .mode == "fence" then
      ("\\A {0,3}" + .fc + "{" + (.fl | tostring) + ",}[ \\t]*\\z") as $close
      | .out += [{code: $l}]
      | if ($l | test($close)) then .mode = "none" else . end
    elif .mode == "html" then
      if .hend == "" then
        if ($l | test("\\A[ \\t]*\\z")) then flush | .out += [{blank: $l}] | .mode = "none" else .buf += [$l] end
      else .hend as $he | .buf += [$l] | if ($l | test($he)) then flush | .mode = "none" else . end end
    elif ($l | test("\\A[ \\t]*\\z")) then flush | .out += [{blank: $l}]
    elif ($l | (contains("```") or contains("~~~")) and test("\\A(?:`{3,}(?!.*`)|~{3,})")) then
      ($l | capture("\\A(?<f>`+|~+)").f) as $f
      | flush | .out += [{code: $l}] | .mode = "fence" | .fc = ($f[0:1] | if . == "`" then "`" else "~" end) | .fl = ($f | length)
    else
      (.kind == "text" and (.buf | length) > 0) as $po
      | (if $l | contains("<") then $l | _rc_scrub_html_start($po) else null end) as $h
      | if $h != null then
          flush | .mode = "html" | .kind = "raw" | .hend = $h | .buf = [$l]
          | if $h != "" and ($l | test($h)) then flush | .mode = "none" | .kind = "text" else . end
        else .kind = "text" | .buf += [$l] end
    end
    | if .mode == "none" and .kind == "raw" and (.buf | length) == 0 then .kind = "text" else . end)
  | flush | .out;

def rc_md_scrub:
  gsub("\u0000"; "")
  | [_rc_scrub_blocks[]
     | if has("code") then .code
       elif has("blank") then .blank
       elif has("raw") then .raw | _rc_scrub_inline("raw")
       else .text | _rc_scrub_defs
            | if ([match(_rc_scrub_re("code"); "g") | .captures[] | select(.name == "lone" and .string != null)] | length > 0)
              then _rc_scrub_inline("text") else _rc_scrub_inline("code") end end]
  | join("\n")
  | (index("\u0000") as $i | if $i == null then . else .[:$i] end)
  | gsub("[\u00ad\u034f\u061c\u115f\u1160\u17b4\u17b5\u180b-\u180f\u200b-\u200f\u202a-\u202e\u2060-\u206f\u3164\ufe00-\ufe0f\ufeff\uffa0󠀀-󠿿]"; "");
