# Palettes

[Custom palettes](https://macterm.thdxg.dev/docs/custom-palettes) anyone can install from **Settings → Palettes** in Macterm. Each is one YAML file here; its file name, without `.yaml`, is the palette's id, and installing it copies the file to `~/.config/macterm/palettes/`.

Macterm reads this folder at the version it was built from — a release reads its own tag, a tip build the `tip` tag — so a palette here only appears in builds that can read it.

## Adding one

1. Write the palette and use it for a while. The [file format](https://macterm.thdxg.dev/docs/custom-palettes) is documented; start the file with the schema line so your editor checks it:

   ```yaml
   # yaml-language-server: $schema=https://raw.githubusercontent.com/thdxg/macterm/main/assets/palette.schema.json
   ```

2. Copy it here as `<id>.yaml`. The id is lowercase letters, digits and `-`, and says what the palette is about (`kubernetes`, not `k8s-tools-v2`).
3. Run `mise run test`. It reads every file here through Macterm's validator.
4. Open a pull request.

## What a palette here needs

- **`name`, `icon` and `description`.** The description is one line that starts with a verb and says what the palette is for: *Follow a running container's logs or open a shell in it*.
- **`requires:`** naming every program its commands need, so a missing one is reported by name.
- **POSIX `sh` commands**, or a script with a `#!` line for anything sh can't do well. Never your own shell's syntax: the palette runs the same for everyone.
- **Values passed as variables** (`"$POD"`), never pasted into a command's text.
- **No side effects in a listing.** Listing runs every time its screen opens; changes belong in an action the user picks.
- **A `when:` where a palette or row can't work** — a daemon that isn't running, a cluster that doesn't answer — with its own short timeout, and an unchecked way out where one exists (Contexts in Kubernetes).
- **Nothing that downloads and runs code** (`curl … | sh`), and nothing that sends data anywhere the user didn't pick.

Every command in a palette runs on the machine of whoever installs it, so review reads each one.
