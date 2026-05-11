#!/usr/bin/env python3
"""
Extract Phase and User Stories sections from a PM agent draft file and
write them to stdout for appending to docs/prd.md.

Usage: python3 orchestrator/extract-prd-sections.py <draft-file>
"""
import re, sys

content = open(sys.argv[1]).read()

kept = []

# Find Phase sections
phase_blocks = re.findall(
    r'(^## Phase \d+.*?)(?=^## (?!Phase \d+.*?###)|^## User stories|\Z)',
    content, re.MULTILINE | re.DOTALL
)
for block in phase_blocks:
    kept.append(block.strip())

# Find User stories section
stories_match = re.search(
    r'(^## User stories.*?)(?=^## (?!EP-)|\Z)',
    content, re.MULTILINE | re.DOTALL
)
if stories_match:
    kept.append(stories_match.group(1).strip())

if not kept:
    print("WARNING: No phase or user story sections found to extract", file=sys.stderr)
    sys.exit(1)

# Add a separator before appending
print("\n\n---\n")
print("\n\n---\n\n".join(kept))
