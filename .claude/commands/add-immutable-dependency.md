# add-immutable-dependency

Adds an external library as an immutable dependency with full source access.

## Usage
```bash
.claude/scripts/add-immutable-dependency.sh <repository>
```

## Arguments
- `repository` (required): The repository URL of the external library (e.g., OpenZeppelin)

## What It Does
1. Clones the full repository to `lib/immutable/`
2. Preserves all source code for complete access

## Important Notes
- Use this for external libraries that won't change based on sibling requirements
- Full source code is available for these dependencies

ARGUMENTS: $ARGUMENTS
