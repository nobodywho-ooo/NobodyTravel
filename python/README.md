# nobodytravel

Build an offline city guide from English Wikivoyage. The pipeline saves Markdown pages and mobile WebP photographs, then adds up to 20 relevant nearby destinations and travel topics.

## Run

From this directory:

```bash
uv run nobodytravel Copenhagen
```

Set `--max-additional=0` to disable link-based expansion. For a quicker test using only the root city article:

```bash
uv run nobodytravel Copenhagen --root-only
```

Output is written to `data/<city>/pages` and `data/<city>/images`. Image attribution is stored in `pages/_attributions.md`, and `links.txt` contains every unique link found in the source pages.

Run `make help` to see the development commands.
