#!/bin/bash
# Functions for working with version numbering.

# Turn a version code (e.g. 2015B-test.1.1.1) into an OcsVersion (e.g. OcsVersion("2015B", true, 1, 1, 1)).
function toOcsVersion() {
python - "$1" <<EOF
import sys
import re
for v in sys.argv[1:]:
    match = re.match(r'^(\d{4}[AB])(-test)?\.(\d+)\.(\d+)\.(\d+)$', v.strip())
    if match:
        g = match.group
        print 'OcsVersion("{0}", {1}, {2}, {3}, {4})'.format(g(1), str(g(2) != None).lower(), g(3), g(4), g(5))
EOF
}

# Extract an OcsVersion (e.g. OcsVersion("2015B", true, 1, 1, 1)) from a string and turn it into a a version
# code (e.g. 2015B-test.1.1.1).
function fromOcsVersion() {
python - "$1" <<EOF
import sys
import re
for v in sys.argv[1:]:
    match = re.match(r'.*OcsVersion\(\s*"(\d{4}[AB])"\s*,\s*(true|false)\s*,\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*\).*', v)
    if match:
        g = match.group
        print '{0}{1}.{2}.{3}.{4}'.format(g(1), '-test' if g(2) == 'true' else '', g(3), g(4), g(5))
EOF
}
