#!/bin/bash
# Test runner for all 1im examples
# Runs each example through the compiler and executes the resulting binary

set -e

COMPILER="./compiler/zig-out/bin/1im"
EXAMPLES_DIR="./examples"
CODEGEN_DIR="./examples/codegen"

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo "========================================="
echo "1im Language - Test All Examples"
echo "========================================="
echo ""

# Check if compiler exists
if [ ! -f "$COMPILER" ]; then
    echo -e "${RED}Error: Compiler not found at $COMPILER${NC}"
    echo "Please build the compiler first with: cd compiler && zig build"
    exit 1
fi

# Create codegen directory if it doesn't exist
mkdir -p "$CODEGEN_DIR"

# Track results
total=0
passed=0
failed=0

# Find all .1im files
for example in "$EXAMPLES_DIR"/*.1im; do
    if [ -f "$example" ]; then
        total=$((total + 1))
        basename=$(basename "$example" .1im)
        
        echo -e "${YELLOW}Testing: $basename${NC}"
        echo "-----------------------------------"
        
        # Show the source code
        echo "Source code:"
        cat "$example"
        echo ""
        
        # Compile and run
        if output=$($COMPILER "$example" 2>&1); then
            echo -e "${GREEN}✓ Compilation successful${NC}"
            
            # Check if binary was generated
            binary="$CODEGEN_DIR/$basename"
            if [ -f "$binary" ]; then
                echo "Generated files:"
                echo "  - C code: $CODEGEN_DIR/$basename.c"
                echo "  - Binary: $binary"
                echo ""
                
                # Run the binary
                echo "Execution output:"
                if result=$($binary 2>&1); then
                    echo "$result"
                    echo -e "${GREEN}✓ Execution successful${NC}"
                    passed=$((passed + 1))
                else
                    echo "$result"
                    echo -e "${RED}✗ Execution failed${NC}"
                    failed=$((failed + 1))
                fi
            else
                echo -e "${RED}✗ Binary not generated${NC}"
                failed=$((failed + 1))
            fi
        else
            echo "$output"
            echo -e "${RED}✗ Compilation failed${NC}"
            failed=$((failed + 1))
        fi
        
        echo ""
        echo "========================================="
        echo ""
    fi
done

# Summary
echo ""
echo "========================================="
echo "Test Summary"
echo "========================================="
echo "Total tests:  $total"
echo -e "Passed:       ${GREEN}$passed${NC}"
echo -e "Failed:       ${RED}$failed${NC}"
echo "========================================="

if [ $failed -eq 0 ]; then
    echo -e "${GREEN}All tests passed!${NC}"
    exit 0
else
    echo -e "${RED}Some tests failed.${NC}"
    exit 1
fi
