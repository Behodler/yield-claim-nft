# update-mutable-dependency

Updates an existing mutable dependency to pull the latest interface changes.

## Usage
```bash
.claude/scripts/update-mutable-dependency.sh <dependency-name>
```

## Arguments
- `dependency-name` (required): The name of the mutable dependency in `lib/mutable/`

## What It Does
1. Reverts local changes to restore the full repository
2. Pulls the latest changes from the remote
3. Verifies the interfaces directory still exists
4. Strips implementation details again, keeping only interfaces

## When to Use
- After a sibling submodule has implemented your change requests
- To sync with the latest interface definitions

ARGUMENTS: $ARGUMENTS
