# claude-fill.nvim

Asks a headless Claude to write code for a region of a Neovim buffer, using a shared, pre-built understanding of the project.

## Language

**Fill**:
One request for Claude to produce code for a single Target.
_Avoid_: request, job, completion, generation

**Target**:
The region of a buffer whose contents a Fill replaces; an empty Target is an insertion point.
_Avoid_: section, selection, hole, range

**Instruction**:
The text the user writes to tell a Fill what the Target should become.
_Avoid_: prompt, query

### Fill outcomes

Every Fill ends in exactly one of these.

**Applied**:
The Fill's replacement was written into its Target.

**Declined**:
Claude judged the Instruction ambiguous or impossible and gave a reason instead of a replacement.
_Avoid_: refused, rejected

**Discarded**:
The Target was edited while the Fill ran, so its replacement was not written.
_Avoid_: conflicted, stale fill

**Cancelled**:
The user stopped the Fill before it finished.

**Failed**:
The Fill could not produce a usable answer, including when its Primer could not be built.
_Avoid_: errored

### Primers

**Primer**:
A Claude session that has explored a project root, from which every Fill in that root is forked.
_Avoid_: base session, exploration context, warm session

**Stale Primer**:
A Primer built at a git HEAD other than its Project root's current one; still usable while its replacement is built.
_Avoid_: old primer, expired primer

**Project root**:
The git root of the buffer a Fill is started from; each Project root has at most one Primer.
_Avoid_: workspace, cwd
