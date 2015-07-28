#!/bin/bash
# General purpose functions.

# Turn a path - possibly nonexistent - into an absolute path.
# If no args are given, uses pwd automatically.
# Note we use python's os.path.abspath function for this, as it is far more robust than
# anything offered or easily implemented in bash.
function absPath() {
python - "$1" <<EOF
import sys
import os.path
for arg in sys.argv[1:]: print os.path.abspath(arg)
EOF
}


# Determines if an element is in an array.
# Usage: contains elem array
# Returns 0 if elem in array, 1 otherwise.
function contains() {
  local e
  for e in "${@:2}"; do [[ "$e" == "$1" ]] && return 0; done
  return 1
}
