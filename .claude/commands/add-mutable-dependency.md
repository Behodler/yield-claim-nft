# add-mutable-dependency

Adds a sibling submodule as a mutable dependency, exposing only interfaces.

## Usage
```bash
.claude/scripts/add-mutable-dependency.sh <repository>
```

## Arguments
- `repository` (required): The repository URL or path of the sibling submodule

## What It Does
1. Clones the repository to `lib/mutable/`
2. Verifies an `src/interfaces/` directory exists
3. Removes all implementation details, keeping only interfaces
4. Reports success or failure

## Important Notes
- Mutable dependencies only expose interfaces and abstract contracts
- Implementation details are automatically stripped
- If the dependency lacks an interfaces directory, the operation fails

ARGUMENTS: $ARGUMENTS
