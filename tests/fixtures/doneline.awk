function ac_doneline(line, f,    rest, rp, seg, grp, searchpos, pre, pp, i, n, fpos, fseg, flast, flaststart, cand, bafter, hpos, hseg, hgrp, hcontent, idend, runpos, inrun, gstart, gend, positional, between, leftch, rightch, quoted, ctok, cn, ci, callkv, dauth) {
  f["id"] = ""; f["terminal"] = ""; f["hold"] = ""; f["hold_until"] = ""; f["hold_malformed"] = ""; f["epic"] = ""; f["feature"] = ""
  f["blockers"] = ""; f["blockers_malformed"] = ""; f["date"] = ""; f["verb"] = ""; f["contract"] = ""
  f["domain"] = ""; f["domain_malformed"] = ""
  rest = line
  sub(/^- \[[ x]\] /, "", rest)
  split(rest, rp, " ")
  f["id"] = rp[1]
  if (rp[2] == "[EPIC]")           f["terminal"] = "epic"
  else if (rp[2] == "[failed]")    f["terminal"] = "failed"
  else if (rp[2] == "[abandoned]") f["terminal"] = "abandoned"
  # Every top-level `[...]` group on the line, not just rp[2]; matched on the
  # `@` SENTINEL, not the bare word - see f["hold"] above for why. Structural
  # (requires the literal bracket syntax) AND immune to a free-text tag's
  # ordinary prose use of "held"/"hold" as a verb. hold_malformed's rule (2)
  # (see f["hold_malformed"] above) needs no sentinel: a ONE-WORD group is
  # never prose, so "held"/"hold" alone in one is still a hold attempt.
  # POSITION decides AUTHORITY: only a group in the LEADING RUN - the id's own
  # `[...]` groups, contiguous, nothing but whitespace between them - can set
  # hold=1. A CODE SPAN decides QUOTATION: a group wrapped in backticks is a
  # documentation mention, never a token and never an attempt, wherever it
  # sits. A bare (unquoted) token-shaped group OUTSIDE the leading run still
  # falls to hold_malformed instead of "no match" - never silently READY.
  match(line, /^- \[[ x]\] [^ \t]+/)
  idend = RLENGTH
  hpos = idend + 1
  runpos = hpos
  inrun = 1
  while (1) {
    hseg = substr(line, hpos)
    if (hseg == "" || !match(hseg, /\[[^][]*\]/)) break
    gstart = hpos + RSTART - 1
    hgrp = substr(line, gstart, RLENGTH)
    gend = gstart + RLENGTH - 1
    positional = 0
    if (inrun) {
      between = substr(line, runpos, gstart - runpos)
      if (between ~ /^[ \t]*$/) { positional = 1; runpos = gend + 1 }
      else inrun = 0
    }
    leftch = ""
    if (gstart > 1) leftch = substr(line, gstart - 1, 1)
    rightch = substr(line, gend + 1, 1)
    quoted = (leftch == "`" && rightch == "`")
    # The delivery-contract group (header note above): leading-run, unquoted,
    # EVERY token key:value from the closed key set, first one wins. No
    # contract-shaped content can also be a hold (the key set spells neither
    # "held" nor "hold"), so claiming the group here steals nothing.
    hcontent = substr(hgrp, 2, length(hgrp) - 2)
    callkv = 0
    if (!quoted && positional && f["contract"] == "" && hcontent != "") {
      cn = split(hcontent, ctok, /[ \t]+/)
      callkv = (cn > 0)
      for (ci = 1; ci <= cn; ci++)
        if (ctok[ci] !~ /^(src|flow|mode|rev|qa|promote):[a-z][a-z-]*$/) { callkv = 0; break }
    }
    if (callkv) {
      f["contract"] = hcontent
    } else if (quoted) {
      # a documentation mention - never a token, never an attempt
    } else if (positional && hgrp ~ /^\[@held( until [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9])?\]$/) {
      f["hold"] = "1"
      if (match(hgrp, /[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/))
        f["hold_until"] = substr(hgrp, RSTART, RLENGTH)
    } else if (tolower(hgrp) ~ /@held|@hold/) {
      f["hold_malformed"] = "1"
    } else {
      hcontent = substr(hgrp, 2, length(hgrp) - 2)
      if (hcontent !~ /[ \t]/ && tolower(hcontent) ~ /held|hold/) f["hold_malformed"] = "1"
    }
    hpos = gend + 1
  }
  if (match(line, /epic:[a-zA-Z0-9_-]+/))
    f["epic"] = substr(line, RSTART + 5, RLENGTH - 5)
  if (match(line, /feature:[a-zA-Z0-9_-]+/))
    f["feature"] = substr(line, RSTART + 8, RLENGTH - 8)
  # domain:<name> (crewdomain-token) - see the field notes above. Two-arm
  # position rule inherited from the retired domain_row_tokened; every other
  # occurrence is malformed unless backtick-quoted.
  dauth = 0
  if (match(line, /; domain:[a-z0-9-]+ \(repo: [^()]*\)$/)) {
    seg = substr(line, RSTART, RLENGTH); dauth = RSTART
    match(seg, /domain:[a-z0-9-]+/)
    dauth = dauth + RSTART - 1
    f["domain"] = substr(seg, RSTART + 7, RLENGTH - 7)
  } else if (match(line, /; domain:[a-z0-9-]+$/)) {
    dauth = RSTART + 2
    f["domain"] = substr(line, RSTART + 9, RLENGTH - 9)
  }
  hpos = 1
  while (1) {
    hseg = substr(line, hpos)
    if (hseg == "" || !match(hseg, /domain:[a-z0-9-]+/)) break
    gstart = hpos + RSTART - 1
    gend = gstart + RLENGTH - 1
    leftch = (gstart > 1) ? substr(line, gstart - 1, 1) : ""
    rightch = substr(line, gend + 1, 1)
    quoted = (leftch == "`" && rightch == "`")
    if (gstart != dauth && !quoted) f["domain_malformed"] = "1"
    hpos = gend + 1
  }
  # blocked-by is read STRICTLY and its slips are detected LENIENTLY. The
  # strict shape is the pinned one (docs/backlog.md, `blocked-by: id1,id2 -
  # reason`): one space, lowercase, comma-joined with no empty component, and
  # ended by whitespace or end-of-line. Anything else leaves blockers EMPTY -
  # which ac-ready.sh reads as READY - so a one-character slip would authorize
  # starting a story whose dependency is still flying. A line that carries a
  # blocked-by token the strict parse did not consume is therefore MALFORMED,
  # a state its consumers must refuse to schedule. A prose mention of the token
  # trips this too; that is the fail-VISIBLE direction, and the line is one
  # keystroke from legal.
  if (match(line, /blocked-by: [a-zA-Z0-9_-]+(,[a-zA-Z0-9_-]+)*/)) {
    bafter = substr(line, RSTART + RLENGTH, 1)
    if (bafter == "" || bafter == " " || bafter == "\t")
      f["blockers"] = substr(line, RSTART + 12, RLENGTH - 12)
  }
  if (f["blockers"] == "" && tolower(line) ~ /(^|[^a-z0-9_-])blocked-by/)
    f["blockers_malformed"] = "1"
  # Date in the LAST non-nested parenthetical group; verb = the word before it.
  searchpos = 1; grp = ""
  while (1) {
    seg = substr(line, searchpos)
    if (seg == "" || !match(seg, /\([^()]*\)/)) break
    grp = substr(seg, RSTART + 1, RLENGTH - 2)
    searchpos = searchpos + RSTART + RLENGTH - 1
  }
  if (grp != "" && match(grp, /[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/)) {
    f["date"] = substr(grp, RSTART, RLENGTH)
    pre = substr(grp, 1, RSTART - 1)
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", pre)
    if (pre == "") f["verb"] = "unknown"
    else { split(pre, pp, /[[:space:]]+/); f["verb"] = (pp[1] ~ /^[A-Za-z][A-Za-z_-]*$/) ? pp[1] : "unknown" }
  }
  # Fallback: last YYYY-MM-DD anywhere; verb = the word immediately before it.
  if (f["date"] == "") {
    fpos = 1; flast = ""; flaststart = 0
    while (1) {
      fseg = substr(line, fpos)
      if (fseg == "" || !match(fseg, /[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/)) break
      flaststart = fpos + RSTART - 1
      flast = substr(fseg, RSTART, RLENGTH)
      fpos = flaststart + RLENGTH
    }
    if (flast != "") {
      f["date"] = flast
      pre = substr(line, 1, flaststart - 1)
      sub(/[[:space:]]+$/, "", pre)
      n = split(pre, pp, /[^A-Za-z_-]+/)
      cand = (n > 0) ? pp[n] : ""
      f["verb"] = (cand ~ /^[A-Za-z][A-Za-z_-]*$/) ? cand : "unknown"
    }
  }
}
