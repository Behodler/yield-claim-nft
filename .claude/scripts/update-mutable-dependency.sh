#!/bin/bash

# Check if an argument was provided
if [ $# -eq 0 ]; then
    echo "Error: Please provide the name of the mutable dependency to update"
    echo "Usage: update-mutable-dependency <dependency-name>"
    exit 1
fi

DEP_NAME="$1"
DEP_PATH="lib/mutable/$DEP_NAME"

# Check if dependency exists
if [ ! -d "$DEP_PATH" ]; then
    echo "Error: Mutable dependency '$DEP_NAME' not found in lib/mutable/"
    exit 1
fi

cd "$DEP_PATH" || exit 1

# Revert any changes to restore deleted files
echo "Reverting local changes to restore all files..."
git checkout .
git clean -fd

# Pull latest changes
echo "Pulling latest changes..."
git pull

# Check if interfaces directory exists
if [ ! -d "src/interfaces" ]; then
    echo "Error: No interfaces directory found in updated $DEP_NAME/src/"
    echo "Mutable dependencies must have an interfaces directory"
    exit 1
fi

# Clean up again - keep only interfaces
echo "Cleaning up implementation details, keeping only interfaces..."

# Save interfaces directory temporarily
if [ -d "src/interfaces" ]; then
    cp -r src/interfaces /tmp/interfaces_temp_$$
fi

# Remove all src content except .git
find src -mindepth 1 -maxdepth 1 ! -name '.git*' -exec rm -rf {} +

# Restore interfaces
if [ -d "/tmp/interfaces_temp_$$" ]; then
    mv /tmp/interfaces_temp_$$ src/interfaces
fi

echo "Successfully updated mutable dependency: $DEP_NAME (interfaces only)"
