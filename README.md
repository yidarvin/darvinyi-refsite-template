# darvinyi-refsite-template

A template for **queue-built reference sites**: interactive textbooks and survey
sites where each chapter (or paper) is researched and built one at a time by Claude
Code, from a queue, in a consistent house style, and deployed as a static site on
Vercel.

This is the reusable skeleton. The build *procedure* lives in the companion
`refsite-runner` skill. This repo is the *noun*; the skill is the *verbs*.

## Stack

Vite, React 18, TypeScript, MDX for chapter prose with embedded React widgets,
React Router with readable slugs, Tailwind bound to CSS-variable design tokens.
Static output, no backend.

## Quick start

```bash
npm install
npm run dev          # http://localhost:5173
npm run build        # typecheck + production build into dist/
```

The dev server renders the example Chapter 0, which documents the system itself.

## Deploy

Push to GitHub, import to Vercel (framework preset **Vite**, output **dist**).
`vercel.json` already contains the SPA rewrite so deep links to `/some-slug` work.
To keep it in your local-first world, add your Gitea NAS remote as a mirror:

```bash
git remote add origin      git@github.com:yidarvin/<name>.git
git remote set-url --add --push origin git@github.com:yidarvin/<name>.git
git remote set-url --add --push origin ssh://gitea@<nas>:3030/yidarvin/<name>.git
```

## How the pieces fit

- `content/registry.json` is the database: the ordered list of chapters and their
  status. The home page renders the whole book from it, including unwritten
  chapters as dimmed rows.
- `src/chapters/<slug>.mdx` is a chapter. It uses the shared primitives (`Figure`,
  `Widget`, `ExerciseCard`, `Callout`) and imports its own bespoke figure and
  signature widget from `_figures/` and `_widgets/`.
- `prompts/queue.md` is the run list. The next item is the first PENDING row.
- `src/styles/tokens.css` is the house style, in one place.

## Building chapters

With the `refsite-runner` skill installed at `~/.claude/skills/refsite-runner/`,
open Claude Code in this repo and say **"run the next one"**. To batch unattended:

```bash
claude -p "run the next one" \
  --model 'claude-opus-4-8[1m]' \
  --settings '{"ultracode":true}' \
  --dangerously-skip-permissions
```

## Making this the template on GitHub

Push this repo, then in GitHub: Settings -> **Template repository**. New sites start
from "Use this template", so the skeleton and this README travel with every project.
