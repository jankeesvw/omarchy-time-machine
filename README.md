# Time Machine

Backups you can forget about, until the day you can't.

Time Machine copies your home folder somewhere safe every night, and puts one answer in your bar: when were my files last backed up? Most days that answer is boring. Today, 03:00. Fine, move on. On the day it isn't boring, the icon turns red and stays red until you deal with it.

![Time Machine](screenshots/panel.png)

It keeps every backup, not just the latest one. So when you notice on Thursday that you wrecked a file on Monday, you can go back to Sunday and take it back.

The bar shows one icon and nothing else. No counter, no percentage, no badge tallying something at you all day. A widget that talks constantly is a widget you stop hearing, so this one keeps quiet until something breaks.

## Install

```bash
sudo pacman -S restic
omarchy plugin add https://github.com/jankeesvw/omarchy-time-machine
omarchy plugin enable jankeesvw.time-machine
omarchy bar move jankeesvw.time-machine --section right
```

[restic](https://restic.net) is the thing that does the actual copying. It's excellent, it's boring in the best way, and it's the only thing you need to install.

### The command line

Most of this you can do from the panel. The rest is a command that lives inside the plugin rather than on your `PATH`, so typing `omarchy-time-machine` on its own gets you `command not found`:

```bash
~/.config/omarchy/plugins/jankeesvw.time-machine/bin/omarchy-time-machine
```

Every `omarchy-time-machine ...` line below means that path. If you are going to type it more than once, give it a name:

```bash
alias omarchy-time-machine=~/.config/omarchy/plugins/jankeesvw.time-machine/bin/omarchy-time-machine
```

Put that in your `~/.bashrc` to keep it. The plugin never adds anything to your `PATH` itself, because where your shell looks for commands is yours to decide.

## Point it somewhere

Click the icon in your bar and choose **Create Configuration**. It writes a starter file and opens it in your editor, so you're never staring at a blank buffer wondering what goes in it. What you get looks like this:

```json
{
  "source": "~",
  "destinations": [
    {
      "name": "backup-drive",
      "display_name": "Backup drive",
      "repository": "/run/media/CHANGE-ME/backup/restic",
      "schedule": "*-*-* 03:00:00"
    }
  ]
}
```

`source` is what gets backed up, `repository` is where it goes, and `schedule` says three in the morning, every morning. Point `repository` at your external drive and you're most of the way there.

An external drive is the easy case. It also does a NAS over SSH, or a bucket in the cloud:

```json
{ "name": "drive",   "repository": "/run/media/you/backup/restic" }
{ "name": "nas",     "repository": "sftp:you@nas:/volume1/backup" }
{ "name": "offsite", "repository": "s3:s3.amazonaws.com/my-bucket" }
```

List more than one and the panel lists them all, each with its own schedule and its own history.

Anywhere restic can write works: a local disk, SFTP, a REST server, S3, Minio, Wasabi, Backblaze B2, Azure Blob, Google Cloud Storage, Alibaba OSS, OpenStack Swift, or anything rclone can reach. A drive in your bag and a bucket in the cloud is a good pair: one is fast, the other survives your house.

## Pick a password

Your backups are encrypted, and that's not optional. An external drive gets lost, a NAS gets stolen, a bucket in the cloud sits on somebody else's computer. Encrypted means that when your backup ends up somewhere you didn't intend, it's noise to whoever finds it.

The price of that is a password. Pick one and it gets stored on this machine, so you'll never be asked for it again in normal use:

```bash
omarchy-time-machine key set --dest backup-drive
omarchy-time-machine init --dest backup-drive
omarchy-time-machine install
```

Those three lines set the password, prepare the destination, and switch on the nightly schedule. That's the setup done. Go do something else.

## Now save that password somewhere else

Read this bit. It's the one thing that quietly makes backups worthless.

Your password is stored in your home folder, and your home folder is what gets backed up. So the copy that ends up inside your backup is locked behind the very password you'd be trying to recover. If this laptop is stolen or dies, your backups are a pile of bytes that nobody can open. Not you, not me, not restic.

```bash
omarchy-time-machine key show --dest backup-drive
```

Put that in your password manager. Print it and put it in a drawer. Do it today, because the moment you need it is exactly the moment you can't get to it.

If you use 1Password, there's a shortcut:

```bash
omarchy-time-machine key save-1password --dest backup-drive
```

That writes it into your vault as "Time Machine backup key (backup-drive)", with a note saying which destination it opens. It refuses if an item by that name already exists, because two of them is how you end up trying the wrong one in a year.

## Getting files back

Open the panel and hit **Restore Files**. Pick a day, then browse to whatever you're looking for, the same way you'd browse any folder.

![Browsing a backup](screenshots/restore.png)

Arrows move through the list, Enter opens a folder, and typing filters what you see. Switch to a different day and you stay in the same folder, so you can flip between Monday and Sunday to spot what changed.

You can bring back a single file, or the whole folder you're standing in.

Everything you restore lands in `~/Restored/`, never on top of your current files. That's deliberate. Getting a file back should never destroy the work you did since. You move things into place yourself, where you can see exactly what you're replacing. When a restore finishes you get a notification, and clicking it opens your file manager with the file already selected.

## Things you might want to change

You only need `name` and `repository`. Everything else already has a sensible default.

| Setting | Default | What it's for |
|---|---|---|
| `source` | your home folder | What gets backed up. A path, or a list of them: `["~", "/etc", "/srv/data"]`. If one is missing the backup stops rather than quietly taking half of it. |
| `exclude_file` | `excludes.txt` next to your config | Things to skip. Caches, downloads, virtual machine images. Anything you can get back another way. |
| `retention` | 7 daily, 4 weekly, 12 monthly, 3 yearly | How far back you can go. Older backups get thinned out rather than kept forever. |
| `schedule` | none | When it runs. `"*-*-* 03:00:00"` is every night at three. Leave it out and this destination only runs when you press the button. |
| `display_name` | the `name` | What the panel calls it. "The drive in my bag" reads better than `usb2`. |
| `pre_command` | none | A command to wake the destination first. See below. |
| `on_failure_command` | none | A command to run when a backup fails, if a red icon isn't enough. |

Run `omarchy-time-machine install` again after changing a schedule.

Times show on a 24-hour clock, to match the Omarchy clock next to it. If you'd rather have AM and PM, that's a setting on the widget in `shell.json`:

```json
{ "id": "jankeesvw.time-machine", "timeFormat": "h:mm AP" }
```

### If your destination isn't always there

A drive that has to be mounted, a NAS that goes to sleep. Without a nudge the backup fails with an unhelpful "repository not found" and you find out days later.

```json
{ "name": "usb",
  "repository": "/run/media/you/backup/restic",
  "pre_command": "systemctl --user start mount-backup-disk" }
```

Whatever you put there runs first, every time. Keep it quick, and make sure it's harmless to run when the destination is already awake.

## If something goes wrong

The panel tells you when the last backup failed and when the last good one was, which is usually the thing you actually want to know. For the details:

```bash
omarchy-time-machine log --dest backup-drive                 # what happened last night
systemctl --user list-timers 'omarchy-time-machine@*'  # when does it run next
omarchy-time-machine backup --dest backup-drive --dry-run    # test everything, write nothing
omarchy-time-machine check --dest backup-drive               # verify the backup isn't damaged
```

To see what you have set up and when each one last ran:

```
$ omarchy-time-machine destinations
NAME           LABEL                  WHERE                                  SCHEDULE       LAST BACKUP
nas            Synology in the cup... sftp:me@nas:/volume1/backup            *-*-* 03:00:00 2026-08-25 03:07
usb            Drive in my bag        /run/media/me/backup/restic            on request     2026-08-18 06:50
offsite        Offsite                s3:s3.eu-central-1.amazonaws.com/attic *-*-* 04:30:00 never

35 snapshots, 373 GB stored in total
```

That reads your settings and one local file, nothing else, so it answers straight away whether or not the drive is plugged in.

You can drive the whole thing from the terminal if you prefer. `omarchy-time-machine` on its own lists what it can do.

## Uninstalling

```bash
omarchy plugin remove jankeesvw.time-machine
```

That removes the widget and leaves your schedule, settings and backup password alone, because taking away a widget shouldn't take away your ability to open your backups. When you want those gone as well:

```bash
systemctl --user disable --now 'omarchy-time-machine@*.timer'
rm -f ~/.config/systemd/user/omarchy-time-machine*
systemctl --user daemon-reload

rm -rf ~/.config/omarchy-time-machine        # settings and your backup password
rm -rf ~/.local/state/omarchy-time-machine   # history and logs
```

Careful with the first one. It holds the password to your backups, and deleting it without a copy elsewhere makes them permanently unreadable. The second holds a record of when each backup ran, plus a log of every run for the last thirty days, which includes the names of files that couldn't be read.

None of this touches the backups themselves. They stay exactly where they are, and anyone with the password can still open them.

## Licence

MIT.

`icon.svg` embeds the `fa-history` outline from [Font Awesome Free](https://fontawesome.com), licensed CC BY 4.0.

The wallpaper behind the screenshots is a pattern built from [Heroicons](https://heroicons.com), licensed MIT, Copyright (c) Tailwind Labs, Inc.
