function fam(p,   n, a) { n = split(p, a, "/"); return (n >= 2 ? a[n - 1] : p) }
/^- \[[^]]*\] [^>]*> (GATE|ASK)( [A-Za-z0-9_-]+)?( \([^)]*\))?:/ { open[FILENAME]++ }
/^- \[[^]]*\] [^>]*> DECIDED( [A-Za-z0-9_-]+)?( \([^)]*\))?:/ { if (open[FILENAME] > 0) open[FILENAME]-- }
/^- \[[^]]*\] [^>]*> HANDBACK:/ { hb[FILENAME] = 1 }
/^- \[[^]]*\] [^>]*> HANDBACK-REFUSED:/ { hb[FILENAME] = 0 }
/^- \[[^]]*\] [^>]*> (DEMOTED|CLOSED):/ { hb[FILENAME] = 0 }
/^- \[/ { last[FILENAME] = $0 }
END {
  for (i = 1; i < ARGC; i++) {
    f = ARGV[i]
    p = (open[f] > 0 ? open[f] : 0)
    print p "\037" (hb[f] + 0) "\037" fam(f) "\037" last[f]
  }
}
