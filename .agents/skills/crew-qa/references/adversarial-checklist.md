# Adversarial input checklist (testplan derivation aid)

What "adversarial" concretely means when deriving negative/boundary cases.
Pick what applies to the change's surface; every picked item becomes a case.

## Input boundaries
- empty / null / missing field; whitespace-only; zero-length arrays
- max-length +1; numeric min-1 / max+1; zero; negative where positive expected
- unicode: emoji, RTL text, combining marks, NUL bytes in strings
- duplicate keys / repeated params; unexpected extra fields

## Injection probes (changed endpoints only)
- SQL meta-characters in string params (`' OR 1=1 --`)
- path traversal in file/name params (`../../etc/passwd`)
- HTML/script in text that gets rendered (`<script>alert(1)</script>`)
- command separators in anything passed to a shell (`; id`)

## State and sequence
- replay the same request twice (idempotency); out-of-order steps
- act on a deleted/nonexistent resource id; someone else's resource id
- concurrent mutation of the same resource (two rapid requests)
- expired/invalid auth token; missing auth header entirely

## Web tier
- double-click the submit; back button after submit; refresh mid-flow
- viewport extremes (mobile width); slow-network first paint
- form autofill garbage; paste-with-formatting into rich inputs

## Before you file a defect (the finding-authority read)
- name the AUTHORITY for the expected behavior: whose rule is it, and where
  (`file:line`, a URL, `captain <date>`)? Nothing citable for an out-of-system
  actor - partner, client library, DB, network - means `unverifiable --note`,
  never a defect
- a citation that CONTRADICTS your finding refutes it: re-read before filing
- read the repro's `# DISPUTED:` / `# HELD-CONSTANT:` headers against the
  script body and say whether they agree - a repro whose two legs differ in
  more than the disputed variable proves nothing, however often it was run

## Time and environment
- boundary timestamps (midnight, month end, DST change, epoch 0)
- timezone-sensitive display vs storage
- dependency down mid-request (stop the mock, assert graceful failure)
