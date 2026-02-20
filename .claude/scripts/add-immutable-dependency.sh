#!/bin/bash

# Check if an argument was provided
if [ $# -eq 0 ]; then
    echo "Error: Please provide a repository URL or path for the immutable dependency"
    echo "Usage: add-immutable-dependency <repository>"
    exit 1
fi

REPO="$1"
# Extract repo name from URL/path
REPO_NAME=$(basename "$REPO" .git)

# Clone the repository to lib/immutable
echo "Cloning immutable dependency: $REPO_NAME"
cd lib/immutable || exit 1
git clone "$REPO" "$REPO_NAME"

echo "Successfully added immutable dependency: $REPO_NAME"
