# Extensions

Extensions anyone can install from **Settings → Extensions** in Macterm. Each is a folder here, named by its id:

```
extensions/
  kubernetes/
    extension.yaml    # its name, description and authors
    README.md         # what it does, for people
    palettes/         # what it adds to the command palette
      kubernetes.yaml
      contexts.yaml   # as many as it needs, each its own palette
    screenshots/      # optional: up to 6 PNGs, each exactly 1600×1000
      screenshot-1.png
```

An extension is what someone installs; what it can do comes from its capabilities. Today that is palettes: each file in `palettes/` is a screen in the command palette with its own name and description. More kinds of capability will be more folders beside `palettes/`.

Installing one copies its folder to `~/.config/macterm/extensions/<id>/`. Its commands can reach the other files in it through `$MACTERM_EXTENSION_DIR` — a script too long to sit in the YAML, say: `list: "$MACTERM_EXTENSION_DIR/list.sh"`.

Every Macterm reads this folder on `main`, whatever its version, so a merged extension is offered to everyone at once. Macterm only ever adds to what an extension can say, never changes or removes it, so an extension that works keeps working after every update. One that uses something newer than someone's Macterm is shown to them as needing an update.

## Adding one

You don't need the whole repository. Either:

- **In the browser:** on GitHub, open `extensions/`, choose **Add file → Create new file**, and type `<id>/extension.yaml` as the name — the `/` makes the folder. Add the other files the same way. GitHub forks the repository and opens the pull request for you.
- **With git**, check out only this folder:

  ```sh
  git clone --filter=blob:none --sparse --depth 1 https://github.com/<you>/macterm.git
  git -C macterm sparse-checkout set extensions
  ```

  It downloads the top-level files and this folder — well under a megabyte — and commits and pushes like any clone.

Then:

1. Write its palettes in `palettes/` and use them for a while; the [file format](https://macterm.thdxg.dev/docs/extensions) is documented. Start each with the schema line so your editor checks it:

   ```yaml
   # yaml-language-server: $schema=https://raw.githubusercontent.com/thdxg/macterm/main/assets/palette.schema.json
   ```

   To try the whole extension, put the folder in `~/.config/macterm/extensions/` — Macterm reads it on the next ⌘P.
2. Add `extension.yaml`:

   ```yaml
   # yaml-language-server: $schema=https://raw.githubusercontent.com/thdxg/macterm/main/assets/extension.schema.json
   name: Kubernetes
   description: Browse a cluster's namespaces, pods, deployments and services
   icon: shippingbox
   authors: [your-github-username]
   ```

3. Add a `README.md` saying what it does, what it needs, and anything to set up first. Settings links to it from the extension's card.
4. Optionally, add screenshots — see below.
5. Open a pull request. CI reads every extension here through Macterm's validator.

## What an extension needs

- **A folder name** that is its id: lowercase words joined by `-`, saying what it is about (`kubernetes`, not `k8s-tools-v2`).
- **`extension.yaml`** with a `name`, a one-line `description` that starts with a verb, and `authors:`, the GitHub usernames of the people who maintain it. A change to an extension someone else wrote needs their approval in the pull request.
- **At least one palette** in `palettes/`.
- **`README.md`**.
- **Files under 500 KB each**, all of them text but the screenshots.
- **Screenshots, if any, in `screenshots/`**: at most 6 PNGs, each exactly 1600×1000 pixels, so every extension's look the same in the gallery.

## Screenshots

Take them with Macterm, which frames the command palette the same way every time:

1. Install your extension (or keep it as a file in `~/.config/macterm/palettes/`) and open the screen you want to show.
2. Run **Capture Palette Screenshot** — bind it to a key in Settings → Keymaps and press it with the palette open; from the menu (View) or the palette itself it captures the palette's first screen.
3. Save it in your extension's `screenshots/` folder. For an installed extension Macterm offers that folder.

The first time, macOS asks to let Macterm record the screen: the palette's glass shows what's behind it, which only a screen capture gets. Your theme and background show through; the size and framing are the same for everyone.

And each palette:

- **`name`, `icon` and `description`.** The description is one line that starts with a verb and says what the palette is for: *Follow a running container's logs or open a shell in it*.
- **`requires:`** naming every program its commands need, so a missing one is reported by name.
- **POSIX `sh` commands**, or a script with a `#!` line for anything sh can't do well. Never your own shell's syntax: the palette runs the same for everyone.
- **Values passed as variables** (`"$POD"`), never pasted into a command's text.
- **No side effects in a listing.** A listing runs every time its screen opens; changes belong in an action the user picks.
- **A `when:` where it can't always work** — a daemon that isn't running, a cluster that doesn't answer — with its own short timeout, and an unchecked way out where one exists (Contexts in Kubernetes).
- **Nothing that downloads and runs code** (`curl … | sh`), and nothing that sends data anywhere the user didn't pick.

Every command in an extension runs on the machine of whoever installs it, so review reads each one.
