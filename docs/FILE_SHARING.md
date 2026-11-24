# Files between iOS and Linux

Open **Home → Files**, **Debian → Files & Apple Files**, or **Settings → Linux Environment → File Sharing**.

## Apple Files (Full Debian Root Filesystem)

DebianRunner embeds a native iOS File Provider extension (`iSHFileProvider.appex`) that mounts your entire Debian Minimal root filesystem (`/`) directly in Apple's **Files** app:

1. Open Apple **Files → Browse → Locations**.
2. Tap **⋯ → Edit** and enable **DebianRunner** if it is not already toggled on.
3. Open **DebianRunner → Debian Minimal** to browse, copy, edit, create, or delete files anywhere in Linux (`/`).

Full rootfs mounting requires both DebianRunner and its File Provider extension to share an iOS App Group entitlement (supported by AltStore, SideStore, Sideloadly, and Xcode). If signed without an App Group, **DebianRunner Shared** below still works with any signature.

## DebianRunner Shared

1. Open the destination folder in **Shared Files**; **New Folder** creates a subfolder.
2. Choose **Import File Here**, then select a regular file in the native Files picker.
3. Wait for completion. In Debian, access `/mnt/LinuxRunnerShared` or `~/Shared`.

The configured Linux account receives a `~/Shared` alias when that name is free. An existing file, folder, or alias is preserved. `/mnt/LinuxRunnerShared` remains the explicit shared location.

In iOS Files, browse **On My iPhone/iPad → DebianRunner → Shared**.

## Linked Folders

Under **Folders from Files**, tap **Add Folder…** to link any folder from iCloud Drive, On My iPhone/iPad, a USB drive, or a file server. Debian sees it at `/mnt/<name>`. Removing a link never deletes the underlying files.

## Export

Select a file in **Shared Files**, then choose **Save to Files…**. For a directory, open it and choose **Export This Folder as ZIP** (or use its context menu).

## Limits and recovery

- Data streams in 64 KiB blocks; imports and exports are limited to 512 MiB. ZIP exports allow at most 4096 entries and 32 directory levels.
- Unicode filenames are preserved; existing names are never overwritten.
- Symbolic links, special files, and paths escaping the shared directory are refused.
- Cancellation removes unpublished temporary copies. A source modified during copying raises an error rather than reporting false success.

See [Troubleshooting](TROUBLESHOOTING.md) if a file transfer or linked folder check fails.
