#!/bin/bash

# Check if an argument was provided
if [ $# -eq 0 ]; then
    echo "Error: Please provide a repository URL or path for the mutable dependency"
    echo "Usage: add-mutable-dependency <repository>"
    exit 1
fi

REPO="$1"
# Extract repo name from URL/path
REPO_NAME=$(basename "$REPO" .git)

# Clone the repository to lib/mutable
echo "Cloning mutable dependency: $REPO_NAME"
cd lib/mutable || exit 1
git clone "$REPO" "$REPO_NAME"

# Check if interfaces directory exists
if [ ! -d "$REPO_NAME/src/interfaces" ]; then
    echo "Error: No interfaces directory found in $REPO_NAME/src/"
    echo "Mutable dependencies must have an interfaces directory"
    rm -rf "$REPO_NAME"
    exit 1
fi

# Perform post-clone cleanup - keep only interfaces
echo "Cleaning up implementation details, keeping only interfaces..."
cd "$REPO_NAME" || exit 1

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

echo "Successfully added mutable dependency: $REPO_NAME (interfaces only)"
