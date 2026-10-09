# Extensions

Anyone can install these extensions from **Settings → Extensions** in Macterm. Each extension is a folder here. The folder name is the id of the extension:

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

A person installs an extension. The capabilities of the extension decide what it can do. Today an extension can add palettes. Each file in `palettes/` is a screen in the command palette, with its own name and description. A future kind of capability will be a new folder next to `palettes/`.

When you install an extension, Macterm copies its folder to `~/.config/macterm/extensions/<id>/`. A command in the extension can reach the other files in the folder through `$MACTERM_EXTENSION_DIR`. For example, a script that is too long for the YAML: `list: "$MACTERM_EXTENSION_DIR/list.sh"`.

Every version of Macterm reads this folder on `main`. When a pull request merges, everyone sees the new extension at once. Macterm only adds to what an extension can say. It never changes or removes it. An extension that works keeps working after every update. If an extension uses a feature that is newer than the Macterm of a person, Macterm tells that person that the extension needs an update.

## Add an extension

You do not need the whole repository. Use one of these two ways:

- **In the browser.** On GitHub, open `extensions/`. Select **Add file → Create new file**. Type `<id>/extension.yaml` as the name. The `/` makes the folder. Add the other files in the same way. GitHub forks the repository and opens the pull request for you.
- **With git.** Check out only this folder:

  ```sh
  git clone --filter=blob:none --sparse --depth 1 https://github.com/<you>/macterm.git
  git -C macterm sparse-checkout set extensions
  ```

  This downloads the top-level files and this folder. The download is well under one megabyte. You commit and push as in any clone.

Then do these steps:

1. Write the palettes in `palettes/`. Use them for a while. The [file format](https://macterm.thdxg.dev/docs/extensions) is in the docs. Start each file with the schema line, so your editor checks the file:

   ```yaml
   # yaml-language-server: $schema=https://raw.githubusercontent.com/thdxg/macterm/main/assets/palette.schema.json
   ```

   To try the whole extension, put the folder in `~/.config/macterm/extensions/`. Macterm reads it the next time that you press <kbd>⌘P</kbd>.
2. Add `extension.yaml`:

   ```yaml
   # yaml-language-server: $schema=https://raw.githubusercontent.com/thdxg/macterm/main/assets/extension.schema.json
   name: Kubernetes
   description: Browse a cluster's namespaces, pods, deployments and services
   icon: shippingbox
   authors: [your-github-username]
   ```

3. Add a `README.md`. Say what the extension does, what it needs, and what to set up first. GitHub shows the file below the files of the folder. The card of the extension in Settings links to that place.
4. Add screenshots if you want. See "Screenshots" below.
5. Open a pull request. CI reads every extension here with the validator of Macterm.

## What an extension needs

- **A folder name** that is its id. Use lowercase words that you join with `-`. Say what the extension is about (`kubernetes`, not `k8s-tools-v2`).
- **`extension.yaml`** with these keys:
  - `name`.
  - `description`: one line that starts with a verb.
  - `authors`: the GitHub usernames of the people who maintain the extension. A change to an extension that another person wrote needs the approval of that person in the pull request.
- **At least one palette** in `palettes/`.
- **`README.md`**.
- **Files under 500 KB each.** All files are text, except the screenshots.
- **Screenshots, if any, in `screenshots/`.** Use at most 6 PNG files. Each file is exactly 1600×1000 pixels. Then the screenshots of all extensions look the same in the gallery.

## Screenshots

Take the screenshots with Macterm. Macterm frames the command palette in the same way each time:

1. Install your extension, or keep it as a file in `~/.config/macterm/palettes/`. Open the screen that you want to show.
2. Run **Capture Palette Screenshot**. Bind it to a key in Settings → Keymaps, and press the key while the palette is open. If you run it from the menu (View) or from the palette, it captures the first screen of the palette.
3. Save the file in the `screenshots/` folder of your extension. For an installed extension, Macterm offers that folder.

The first time, macOS asks if Macterm can record the screen. The glass of the palette shows what is behind it. Only a screen capture can get that. Your theme and your background show through. The size and the framing are the same for everyone.

## What each palette needs

- **`name`, `icon` and `description`.** The description is one line that starts with a verb. It says what the palette is for. For example: *Follow a running container's logs or open a shell in it*.
- **`requires:`**. List every program that its commands need. Then Macterm reports a missing program by name.
- **POSIX `sh` commands.** For anything that sh cannot do well, use a script with a `#!` line. Never use the syntax of your own shell. The palette must run in the same way for everyone.
- **Values that you pass as variables** (`"$POD"`). Never paste a value into the text of a command.
- **No side effects in a listing.** A listing runs each time that its screen opens. Changes belong in an action that the user selects.
- **A `when:` where the palette cannot always work.** For example, a daemon that is not running, or a cluster that does not answer. Give it a short timeout of its own. Where it is possible, give the user a way out that has no check (Contexts in Kubernetes).
- **No code that downloads and runs code** (`curl … | sh`). No data that goes to a place that the user did not select.

Every command in an extension runs on the machine of the person who installs it. The review therefore reads each command.
