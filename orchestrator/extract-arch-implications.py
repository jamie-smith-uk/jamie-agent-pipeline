#!/usr/bin/env python3
"""
Extract the Architectural implications section from a PM agent draft file.

Usage: python3 orchestrator/extract-arch-implications.py <draft-file>
"""
import re, sys

content = open(sys.argv[1]).read()
m = re.search(r'## Architectural implications\n(.*?)(?=\n## |\Z)', content, re.DOTALL)
print(m.group(1).strip() if m else "See draft for details.")
