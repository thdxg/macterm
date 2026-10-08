# Extensions

Extensions anyone can install from **Settings → Extensions** in Macterm. Each is a folder here, named by its id:

```
extensions/
  kubernetes/
    extension.yaml    # who made it
    palette.yaml      # the palette
    README.md         # what it does, for the gallery and for people
    screenshot.png    # optional
```

Installing one copies its folder to `~/.config/macterm/extensions/<id>/`. Its commands can reach the other files in it through `$MACTERM_EXTENSION_DIR` — a script too long to sit in the YAML, say: `list: "$MACTERM_EXTENSION_DIR/list.sh"`.

Macterm reads this folder at the version it was built from — a release reads its own tag, a tip build the `tip` tag — so an extension here only appears in builds that can read it.

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

1. Write the palette and use it for a while; the [file format](https://macterm.thdxg.dev/docs/extensions) is documented. Start `palette.yaml` with the schema line so your editor checks it:

   ```yaml
   # yaml-language-server: $schema=https://raw.githubusercontent.com/thdxg/macterm/main/assets/palette.schema.json
   ```

2. Add `extension.yaml` naming you by GitHub username:

   ```yaml
   authors: [your-github-username]
   ```

3. Add a `README.md` saying what it does, what it needs, and anything to set up first. Its first paragraph is what Macterm shows before installing it.
4. Open a pull request. CI reads every extension here through Macterm's validator.

## What an extension needs

- **A folder name** that is its id: lowercase words joined by `-`, saying what it is about (`kubernetes`, not `k8s-tools-v2`).
- **`extension.yaml`** with `authors:`, the GitHub usernames of the people who maintain it. A change to an extension someone else wrote needs their approval in the pull request.
- **`README.md`**.
- **Files under 500 KB each**, and images only as PNG, JPEG or WebP.

And its palette:

- **`name`, `icon` and `description`.** The description is one line that starts with a verb and says what the palette is for: *Follow a running container's logs or open a shell in it*.
- **`requires:`** naming every program its commands need, so a missing one is reported by name.
- **POSIX `sh` commands**, or a script with a `#!` line for anything sh can't do well. Never your own shell's syntax: the palette runs the same for everyone.
- **Values passed as variables** (`"$POD"`), never pasted into a command's text.
- **No side effects in a listing.** A listing runs every time its screen opens; changes belong in an action the user picks.
- **A `when:` where it can't always work** — a daemon that isn't running, a cluster that doesn't answer — with its own short timeout, and an unchecked way out where one exists (Contexts in Kubernetes).
- **Nothing that downloads and runs code** (`curl … | sh`), and nothing that sends data anywhere the user didn't pick.

Every command in an extension runs on the machine of whoever installs it, so review reads each one.
