#!/bin/bash
set -euo pipefail
# Run test suite — suppress success output, only show errors
ruby -W0 -Itest -Ilib -e 'Dir.glob("test/**/*_test.rb").each { |f| require_relative f }' 2>&1 | tail -5
