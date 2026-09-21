# Reviewing

The canvas, the cards on it, the edges between them, the comments you leave on their lines,
and the sessions that keep it all where you put it.

## The canvas is a whiteboard

Cards stay where you put them. A new card opens beside the card it was opened from, in the
first clear space there, and nothing already on the canvas moves to make room for it.
`reset layout` in the toolbar lays everything out again.

- Drag a card by its header to move it, or hold Ctrl and drag from anywhere on it. Ctrl and
  press over a card is the drag gesture, so the context menu is suppressed there; a plain
  right-click still opens it.
- Drag the background to pan; hold Space to pan from anywhere, cards included.
- ⌘ or Ctrl with the wheel zooms about the cursor; the wheel alone pans, except over
  something that can scroll itself.
- Arrow keys walk the graph from the focused card.

Placement is a heuristic: it avoids overlap at the moment a card is placed, so a card that
later grows — a diff opened, a thread written — or a card dragged onto another stays where
it is. `reset layout` untangles them.

### Groups and frames

A group of cards is drawn as a frame round the cards themselves, wherever on the canvas they
sit, so two flows on one canvas are read apart rather than run together. The frame follows
its cards: drag one to the edge of a flow and the frame grows with it, header and all. The
header carries the title, how many cards are in it, and `ungroup`, which takes the frame
away and leaves the cards where they were. A title is a label rather than a requirement — a
frame may stand with none, and its heading then reads "Untitled group". Cards in no group
make a last, unframed section under the framed ones.

- **Shift+click** a card to pick it out; Shift+click again to put it back. Its code is the
  comment gutter's, so Shift there stretches the range being written rather than picking the
  card out. Selected cards wear a dashed outline. A plain click says which card you mean
  instead, so it lets the selection go — as do opening a card from the sidebar or the
  palette, and Escape. A card that closes leaves the selection with it. The selection is this
  tab's own: another tab reading the same session sees the frames you make, not the cards you
  are picking.
- **⌘G** frames the selected cards, or the focused card when nothing is selected. **⇧⌘G**
  takes the selected cards back out of whatever frames they are in, leaving them selected,
  so they can go straight into another one.
- **Drag a frame's title** to move the whole group: every card inside travels together and
  keeps its place relative to the others. A click on the title, with no drag, renames the
  group in place — Enter saves, a blank name leaves the frame with none, Escape or clicking
  away leaves it as it was. The group keeps its id and its cards, so an agent holding that
  id still finds it.
- **Drop a card inside another group's frame** — on a card there, in the space between them,
  on the padding at its edge — to move it to that group; drag a selected card and the rest
  of the selection goes with it. Dropping it anywhere else moves the card and nothing more.
- A frame's title keeps its size at any zoom, so you can read which group is which from far
  enough out that the cards inside it are specks.

A card opened from another — a callee by clicking a call, a caller from the callers menu —
joins the group of the card it was opened from when it is new to the canvas, so it lands
beside that card inside the same frame.

## Cards

A card is one function: its header, its `file:line`, and its syntax-highlighted source with
every call it makes clickable.

- **Calls.** Click one to open the callee to the right. Calls the compiler reports at a
  position nothing in the source can be clicked — code a macro generated, or a call in an
  interpolation the extractor could not place — are listed in the card's "Also calls"
  footer.
- **The callers menu** opens a caller to the card's left. Open several and the card keeps
  one edge from each of them.
- **`file:line`** links into your editor when `editor` is configured. A removed function's
  `file:line` is the base commit's, so it is printed rather than linked.
- **Badges.** A card wears a badge for the entry point it is, and in a review against a base
  ref for what the branch did to it. A modified card counts its lines (`+3 −1`) beside the
  title.
- **`diff` / `source`** in a modified card's header swaps its body between the branch's
  source and the diff against the base — deleted lines from the base, inserted lines from
  the branch, highlighted as code either way. The `d` key does the same to the focused card,
  and passes over a card with nothing to compare.
- **`changes only` / `all lines`** folds the unchanged lines away, the way a pull request
  shows a file: the changed lines, three lines of context on either side, every line a
  comment sits on, and one `⋯ n unchanged lines` row per stretch in between, which draws its
  lines when clicked. A function longer than 100 lines arrives folded; a shorter one arrives
  whole. The `h` key does the same to the focused card.
- **Collapse** (`c`) hides the body and leaves the header. **Close** (`x`) takes the card
  off the canvas; `Shift+x` closes it together with everything that had no other way to be
  reached.
- **Signature mode** (`s`, or `signatures` in the toolbar) turns every card down to its
  signature: the body goes, and the header and the syntax-highlighted line naming the
  function are scaled up so they stay readable however far out you are. The header's buttons
  keep working, so you can close or collapse a card without leaving the mode.

A `.heex` template is a card like any other, its markup highlighted and its `file:line`
linked into your editor. A component tag inside it — or inside a `~H` body — is a call site
you click to open the component, and a controller's `render` opens the template it names, so
a route reads through its action and its page into the contexts underneath.

## Edges

An edge runs from a call site to the card it reaches, takes that call site's colour and
arrows into the callee. Double-click an arrow to jump to the card at its far end — the
caller or the callee that is out of sight — which takes focus and pans into view.

## Comments

Click a line number to comment — hover it first for the `+` that marks it clickable. Drag
down or up the line numbers to comment on a range of lines instead of one, and Shift+click a
line number while the composer is open to stretch the range to it, or back to a single line.
⌘/Ctrl+Enter saves, Escape cancels. A thread takes replies, and can be resolved, reopened or
deleted. A resolved thread collapses to one line and expands on click.

In a diff body the line numbers on the base side are clickable the same way, so a thread can
land on a line the branch deleted. A range runs down one side: a drag that crosses to the
other side's numbers stops where it left its own.

A ranged thread tints every line it covers and sits under the last of them. A drag released
below a fold covers the lines the fold hides, and the thread it opens unfolds them.

A thread whose line moved re-anchors wherever its text went. One that matches nowhere sits
in the card's footer, marked outdated. One whose function has left the index is listed muted
in the sidebar and draws nothing.

The sidebar's Comments group lists every open thread under its module and jumps to the line
when you click it.

Comments belong to the project rather than to a session: they are kept in
`.grasp/comments.json` under the directory Grasp was started in, and show on whatever canvas
draws the function. The file travels with the checkout — commit it alongside the changes it
is about if you want the discussion to go with the branch, or add it to `.gitignore` if you
would rather keep review chatter out of the repository.

An agent reads and answers the same threads, and can post them to GitHub. See
[The agent](agent.md) and [Pull requests](pull-requests.md).

## Sessions

A session is one canvas: the cards on it, how they are grouped, where each one sits and
which one has the focus. The session named `default` is the canvas at `/grasp`; any other
name is the canvas at `/grasp/s/<name>`, so a review of one pull request and a walk through
a subsystem sit side by side instead of on top of each other.

The sidebar's header names the session being read and opens the menu of every session the
viewer is running or has saved. A row there goes to that canvas, the × beside it forgets the
session — its file and the agent conversation held under its name go with it — and the field
under the list opens a session by name, existing or new. Session names are letters, digits,
`-` and `_`, up to 40 characters. Deleting the session a tab is reading sends that tab to the
default canvas; deleting `default` itself clears it rather than taking it away, since the
next visit starts it again, empty.

Each session is a file under `.grasp/sessions/` in the project Grasp was started in, written
a moment after the canvas changes and read back when the viewer starts, so quitting and
coming back finds the cards where they were.

`.grasp/index.json` is rebuilt from whatever the checkout holds, so it is worth ignoring in
git, as is `.grasp/worktrees/`. The sessions are not derived from the code: a session is an
arrangement someone made, so commit `.grasp/sessions/` alongside a branch if you want the
canvas to travel with the pull request.
